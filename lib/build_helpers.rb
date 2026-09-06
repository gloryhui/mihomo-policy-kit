# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'tempfile'
require 'open3'
require 'shellwords'
require_relative 'overlay'

module BuildHelpers
  ROOT_DIR = File.expand_path('..', __dir__)

  module_function

  def absolute(path)
    File.expand_path(path.to_s, ROOT_DIR)
  end

  def load_config(path)
    MPK::YAMLUtil.load_file(path)
  end

  def dig(hash, *keys, default: nil)
    current = hash
    keys.each do |key|
      return default unless current.is_a?(Hash) && current.key?(key)

      current = current[key]
    end
    current.nil? ? default : current
  end

  # 执行命令并把输出实时转发到 stdout。
  #
  # log: 显式声明命令的日志显示值。敏感参数（例如订阅 URL / token）由调用方
  #       传入安全占位符（如 "$MPK_SOURCE_URL" 或 "<redacted>"），绝不自动猜测。
  # exec_label: 命令失败时异常消息中使用的标签；省略时退化为 log 显示值。
  def run_streaming(env, *command, log: nil, exec_label: nil)
    display = log || command.join(' ')
    puts "[exec] #{display}"
    status = nil

    Open3.popen2e(env, *command) do |_stdin, output, wait_thread|
      output.each { |line| $stdout.write(line) }
      status = wait_thread.value
    end

    unless status.success?
      label = exec_label || display
      raise MPK::Error, "command failed (#{status.exitstatus}): #{label}"
    end
  end

  # 下载 url 到 path。log 默认只显示环境变量占位符，避免把真实订阅
  # URL / token 输出到终端或 CI 日志；curl 执行时仍使用真实 url。
  def fetch_to(url, path, log: '$MPK_SOURCE_URL')
    FileUtils.mkdir_p(File.dirname(path))
    run_streaming(
      {},
      'curl', '-fL', '--connect-timeout', '15', '--retry', '3', '--retry-delay', '2',
      url, '-o', path,
      log: log,
      exec_label: "subscription download failed (#{log})"
    )
  end

  # 跨平台命令查找。Windows 上使用 PATHEXT 扩展名列表，不依赖 /bin/sh。
  def command_path(command)
    command = command.to_s
    return nil if command.empty?

    win = Gem.win_platform?
    exts = if win
             (ENV['PATHEXT'] || '.COM;.EXE;.BAT;.CMD').split(';').reject(&:empty?).map(&:downcase)
           else
             ['']
           end

    # 显式含路径的命令（相对或绝对）直接解析。
    if command.include?('/') || (win && command.include?('\\')) || command.include?(':')
      return nil if command.include?(':') && !File.exist?(command)

      full = File.expand_path(command)
      return full if File.file?(full) && exec_file?(full, exts, win)

      return nil
    end

    base = File.basename(command)
    candidates = if File.extname(base).empty?
                   exts.map { |ext| base + ext }
                 else
                   [base]
                 end

    path_dirs = ENV['PATH'].to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
    path_dirs << Dir.pwd if path_dirs.empty?

    path_dirs.each do |dir|
      candidates.each do |cand|
        full = File.join(File.expand_path(dir), cand)
        return full if File.file?(full) && exec_file?(full, exts, win)
      end
    end

    nil
  end

  def command_available?(command)
    !command_path(command).nil?
  end

  # Windows 下把 Windows 风格路径转换为当前 bash（Git Bash / WSL2）可解析的
  # POSIX 路径：优先用 wslpath，其次 cygpath；两者都不可用时原样返回。
  # 非 Windows 直接原样返回。
  def bash_path_for(path)
    return path.to_s unless Gem.win_platform?

    converter = bash_path_converter
    return path.to_s if converter.nil?

    escaped = Shellwords.escape(path.to_s)
    stdout, _stderr, status = Open3.capture3('bash', '-c', "#{converter} -u #{escaped}")
    return path.to_s unless status.success?

    converted = stdout.strip
    converted.empty? ? path.to_s : converted
  end

  # 探测 bash 内可用的 Windows->POSIX 路径转换器（wslpath / cygpath）。
  def bash_path_converter
    return @bash_path_converter if defined?(@bash_path_converter)

    @bash_path_converter = begin
      stdout, _stderr, status = Open3.capture3('bash', '-c', 'command -v wslpath || command -v cygpath')
      status.success? ? stdout.strip : nil
    end
  end

  # Windows: 可执行性由 PATHEXT 扩展名决定（不依赖 Unix 执行位）。
  # Unix: 需要真实执行位。
  def exec_file?(path, exts, win)
    return exts.include?(File.extname(path).downcase) if win

    File.executable?(path)
  end
  private_class_method :exec_file?

  def write_and_test(document, output_path)
    FileUtils.mkdir_p(File.dirname(output_path))

    Tempfile.create(['mpk-candidate-', '.yaml'], File.dirname(output_path)) do |tmp|
      tmp.write(YAML.dump(document))
      tmp.flush
      tmp.fsync

      if (mihomo = command_path('mihomo'))
        puts '[validate] running mihomo -t'
        stdout, stderr, status = Open3.capture3(mihomo, '-t', '-f', tmp.path)
        $stdout.write(stdout) unless stdout.empty?
        $stderr.write(stderr) unless stderr.empty?
        raise MPK::Error, "mihomo config test failed (#{status.exitstatus})" unless status.success?
      else
        puts '[validate] mihomo not found; core validation skipped'
      end

      # Windows 上 File.rename/mv 在目标已存在或跨卷时会失败（EACCES），
      # 且 Tempfile 打开句柄会阻止移动；先关闭并移除旧目标。
      tmp.close if tmp.respond_to?(:close) && !tmp.closed?
      File.delete(output_path) if File.file?(output_path)

      begin
        FileUtils.mv(tmp.path, output_path)
      rescue SystemCallError
        FileUtils.cp(tmp.path, output_path, remove_destination: true)
      end
    end
  end
end
