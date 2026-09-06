# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require 'open3'
require 'rbconfig'
require_relative '../lib/build_helpers'

class BuildHelpersTest < Minitest::Test
  SECRET = 'VERY_SECRET_TOKEN_123'
  TEST_URL = "https://example.invalid/sub/#{SECRET}"

  # 当前 Ruby 解释器作为跨平台测试命令（Windows 无 sh 也可运行）。
  def ruby
    RbConfig.ruby
  end

  # 在临时目录里放一个 fake curl，把收到的全部参数写入 -o 指定的文件，
  # 从而在不出网的情况下验证真实 URL 确实被传给了执行层。
  # Windows 需要 PATHEXT 扩展名，因此同时生成 sh 版与 cmd 版。
  def with_fake_curl(exit_status: 0)
    Dir.mktmpdir do |dir|
      write_curl_sh(File.join(dir, 'curl'), exit_status)
      write_curl_cmd(File.join(dir, 'curl.cmd'), exit_status)

      original_path = ENV['PATH']
      ENV['PATH'] = "#{dir}#{File::PATH_SEPARATOR}#{original_path}"
      begin
        yield dir
      ensure
        ENV['PATH'] = original_path
      end
    end
  end

  def write_curl_sh(path, exit_status)
    File.write(path, <<~SH)
      #!/bin/sh
      out=""
      prev=""
      for arg in "$@"; do
        if [ "$prev" = "-o" ]; then out="$arg"; fi
        prev="$arg"
      done
      printf '%s\\n' "$@" > "$out"
      exit #{exit_status}
    SH
    File.chmod(0o755, path)
  end

  def write_curl_cmd(path, exit_status)
    File.write(path, <<~BAT)
      @echo off
      setlocal enabledelayedexpansion
      set "out="
      set "prev="
      for %%a in (%*) do (
        if "!prev!"=="-o" set "out=%%~a"
        set "prev=%%~a"
      )
      > "%out%" echo %*
      exit /b #{exit_status}
    BAT
  end

  def capture_stdout
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    yield
    buffer.string
  ensure
    $stdout = original
  end

  def test_run_streaming_logs_full_command_by_default
    output = capture_stdout do
      BuildHelpers.run_streaming({}, ruby, '-e', 'print "hello\n"')
    end

    assert_includes output, '[exec]'
    assert_includes output, 'hello'
  end

  def test_run_streaming_uses_explicit_log_display_value
    output = capture_stdout do
      BuildHelpers.run_streaming(
        {},
        ruby, '-e', 'exit 0',
        log: '$MPK_SOURCE_URL'
      )
    end

    assert_includes output, '[exec] $MPK_SOURCE_URL'
    refute_includes output, SECRET
  end

  def test_run_streaming_failure_message_uses_exec_label
    error = assert_raises(MPK::Error) do
      capture_stdout do
        BuildHelpers.run_streaming(
          {},
          ruby, '-e', 'exit 3',
          log: '$MPK_SOURCE_URL',
          exec_label: 'subscription download failed ($MPK_SOURCE_URL)'
        )
      end
    end

    assert_match(/command failed \(3\): subscription download failed \(\$MPK_SOURCE_URL\)/, error.message)
    refute_includes error.message, SECRET
  end

  def test_run_streaming_failure_message_falls_back_to_display
    error = assert_raises(MPK::Error) do
      capture_stdout do
        BuildHelpers.run_streaming({}, ruby, '-e', 'exit 1', log: '<redacted>')
      end
    end

    assert_match(/command failed \(1\): <redacted>/, error.message)
  end

  def test_fetch_to_passes_real_url_to_execution_and_redacts_log
    with_fake_curl do |dir|
      target = File.join(dir, 'out.yaml')

      output = capture_stdout do
        BuildHelpers.fetch_to(TEST_URL, target, log: '$MPK_SOURCE_URL')
      end

      # 日志中不出现 secret，且能看到正在执行的下载操作
      assert_includes output, '[exec] $MPK_SOURCE_URL'
      refute_includes output, SECRET

      # 真实 URL 仍被传给执行层
      written = File.read(target)
      assert_includes written, TEST_URL
    end
  end

  def test_fetch_to_default_log_is_env_placeholder
    with_fake_curl do |dir|
      target = File.join(dir, 'out.yaml')

      output = capture_stdout do
        BuildHelpers.fetch_to(TEST_URL, target)
      end

      assert_includes output, '[exec] $MPK_SOURCE_URL'
      refute_includes output, SECRET
    end
  end

  def test_fetch_to_failure_does_not_leak_url
    with_fake_curl(exit_status: 1) do |dir|
      target = File.join(dir, 'out.yaml')

      error = assert_raises(MPK::Error) do
        capture_stdout do
          BuildHelpers.fetch_to(TEST_URL, target, log: '$MPK_SOURCE_URL')
        end
      end

      assert_match(/subscription download failed \(\$MPK_SOURCE_URL\)/, error.message)
      refute_includes error.message, SECRET
    end
  end

  # ---- 跨平台命令发现（Issue #7-05） ----

  def with_path_dir
    Dir.mktmpdir do |dir|
      original_path = ENV['PATH']
      ENV['PATH'] = "#{dir}#{File::PATH_SEPARATOR}#{original_path}"
      begin
        yield dir
      ensure
        ENV['PATH'] = original_path
      end
    end
  end

  def test_command_path_finds_explicit_absolute_path
    # 显式路径（含 .exe / 可执行位）必须能解析，不依赖 PATH
    assert_equal File.expand_path(ruby), BuildHelpers.command_path(ruby)
  end

  def test_command_path_finds_basename_when_dir_on_path
    with_path_dir do |dir|
      ENV['PATH'] = "#{File.dirname(ruby)}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
      assert_equal File.expand_path(ruby), BuildHelpers.command_path(File.basename(ruby))
      assert BuildHelpers.command_available?(File.basename(ruby))
    end
  end

  def test_command_path_finds_mihomo_exe_on_windows
    with_path_dir do |dir|
      fake_name = Gem.win_platform? ? 'mihomo.exe' : 'mihomo'
      fake = File.join(dir, fake_name)
      File.write(fake, 'fake')

      if Gem.win_platform?
        # Windows：PATHEXT 的 .EXE 命中 mihomo.exe
        assert_equal File.expand_path(fake), BuildHelpers.command_path('mihomo')
        assert BuildHelpers.command_available?('mihomo')
      else
        # Unix：需要执行位，且二进制无 .exe 后缀
        assert_nil BuildHelpers.command_path('mihomo')
        File.chmod(0o755, fake)
        assert_equal File.expand_path(fake), BuildHelpers.command_path('mihomo')
        assert BuildHelpers.command_available?('mihomo')
      end
    end
  end

  def test_command_path_finds_bare_script_on_unix_only_via_exec_bit
    with_path_dir do |dir|
      fake = File.join(dir, 'mytool')
      File.write(fake, '#!/bin/sh\n')
      File.chmod(0o644, fake)

      if Gem.win_platform?
        assert_nil BuildHelpers.command_path('mytool')
      else
        assert_nil BuildHelpers.command_path('mytool')
        File.chmod(0o755, fake)
        assert_equal File.expand_path(fake), BuildHelpers.command_path('mytool')
      end
    end
  end

  def test_command_path_missing_returns_nil
    assert_nil BuildHelpers.command_path('mpk-definitely-not-a-real-command-xyz')
  end
# ---- 可恢复 promotion（Sol Review #2） ----

  def test_promote_file_replaces_existing_output_and_cleans_backup
    Dir.mktmpdir do |dir|
      output = File.join(dir, 'out.yaml')
      File.write(output, 'old')
      candidate = File.join(dir, 'candidate.yaml')
      File.write(candidate, 'new')

      BuildHelpers.promote_file(candidate, output)

      assert_equal 'new', File.read(output)
      refute File.exist?(candidate)
      # backup 应被清理（同目录 .mpk-backup-* 不存在）
      backups = Dir.glob(File.join(dir, '.mpk-backup-*'))
      assert_empty backups
    end
  end

  def test_promote_file_without_existing_output
    Dir.mktmpdir do |dir|
      output = File.join(dir, 'out.yaml')
      candidate = File.join(dir, 'candidate.yaml')
      File.write(candidate, 'new')

      BuildHelpers.promote_file(candidate, output)

      assert_equal 'new', File.read(output)
      refute File.exist?(candidate)
    end
  end

  def test_promote_file_restores_backup_when_move_fails
    Dir.mktmpdir do |dir|
      output = File.join(dir, 'out.yaml')
      File.write(output, 'GOOD_OLD_CONTENT')
      candidate = File.join(dir, 'candidate.yaml')
      File.write(candidate, 'NEW_CONTENT')

      # 临时替换 move_file 抛出错误模拟 move 阶段故障（例如权限/杀软占用）
      original = BuildHelpers.method(:move_file)
      BuildHelpers.singleton_class.send(:define_method, :move_file) do |*_args|
        raise Errno::EACCES, 'simulated move failure'
      end

      begin
        error = assert_raises(MPK::Error) do
          BuildHelpers.promote_file(candidate, output)
        end
        assert_match(/promotion failed/, error.message)
      ensure
        BuildHelpers.singleton_class.send(:define_method, :move_file, original)
      end

      # 旧 output 必须仍完整保留（restore 成功路径）
      assert_equal 'GOOD_OLD_CONTENT', File.read(output)
    end
  end

  def test_promote_file_keeps_old_output_intact_on_failure
    Dir.mktmpdir do |dir|
      output = File.join(dir, 'out.yaml')
      File.write(output, 'GOOD_OLD_CONTENT')
      candidate = File.join(dir, 'candidate.yaml')
      File.write(candidate, 'NEW_CONTENT')

      # 模拟 promotion 阶段故障：candidate 在移动前被删除 -> FileUtils.mv 抛 ENOENT
      File.delete(candidate)

      begin
        BuildHelpers.promote_file(candidate, output)
        flunk 'expected promotion to fail'
      rescue MPK::Error
        # 旧 output 必须完整保留（restore 成功路径）
        assert_equal 'GOOD_OLD_CONTENT', File.read(output)
      end
    end
  end

  # Sol Review #2（第二轮）：restore 也失败时，backup 必须真实保留。
  def test_promote_file_keeps_backup_when_restore_fails
    Dir.mktmpdir do |dir|
      output = File.join(dir, 'out.yaml')
      File.write(output, 'GOOD_OLD_CONTENT')
      candidate = File.join(dir, 'candidate.yaml')
      File.write(candidate, 'NEW_CONTENT')

      # 同时让 move_file 与 copy_over 失败，覆盖最坏路径
      original_move = BuildHelpers.method(:move_file)
      original_copy = BuildHelpers.method(:copy_over)
      BuildHelpers.singleton_class.send(:define_method, :move_file) do |*_args|
        raise Errno::EACCES, 'simulated move failure'
      end
      BuildHelpers.singleton_class.send(:define_method, :copy_over) do |*_args|
        raise Errno::EACCES, 'simulated restore failure'
      end

      error = nil
      begin
        BuildHelpers.promote_file(candidate, output)
        flunk 'expected promotion to fail'
      rescue MPK::Error => e
        error = e
      ensure
        BuildHelpers.singleton_class.send(:define_method, :move_file, original_move)
        BuildHelpers.singleton_class.send(:define_method, :copy_over, original_copy)
      end

      refute_nil error, 'should raise MPK::Error'
      assert_match(/promotion failed and restore failed/, error.message)

      # 错误消息中的 backup 路径必须真实存在
      match = /backup kept at (.+)/.match(error.message)
      refute_nil match, "error message should contain backup path: #{error.message}"
      backup_path = match[1].strip
      assert File.file?(backup_path), "backup should exist on disk: #{backup_path}"
      # backup 内容仍是旧 good output
      assert_equal 'GOOD_OLD_CONTENT', File.read(backup_path)
    end
  end
end

