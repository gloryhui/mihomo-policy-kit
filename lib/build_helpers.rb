# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'tempfile'
require 'open3'
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

  def command_available?(command)
    system('sh', '-c', "command -v #{command} >/dev/null 2>&1")
  end

  def write_and_test(document, output_path)
    FileUtils.mkdir_p(File.dirname(output_path))

    Tempfile.create(['mpk-candidate-', '.yaml'], File.dirname(output_path)) do |tmp|
      tmp.write(YAML.dump(document))
      tmp.flush
      tmp.fsync

      if command_available?('mihomo')
        puts '[validate] running mihomo -t'
        stdout, stderr, status = Open3.capture3('mihomo', '-t', '-f', tmp.path)
        $stdout.write(stdout) unless stdout.empty?
        $stderr.write(stderr) unless stderr.empty?
        raise MPK::Error, "mihomo config test failed (#{status.exitstatus})" unless status.success?
      else
        puts '[validate] mihomo not found; core validation skipped'
      end

      FileUtils.mv(tmp.path, output_path)
    end
  end
end
