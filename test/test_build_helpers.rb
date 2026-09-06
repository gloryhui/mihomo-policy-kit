# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'stringio'
require 'open3'
require_relative '../lib/build_helpers'

class BuildHelpersTest < Minitest::Test
  SECRET = 'VERY_SECRET_TOKEN_123'
  TEST_URL = "https://example.invalid/sub/#{SECRET}"

  # 在临时目录里放一个 fake curl，把收到的全部参数写入 -o 指定的文件，
  # 从而在不出网的情况下验证真实 URL 确实被传给了执行层。
  def with_fake_curl(exit_status: 0)
    Dir.mktmpdir do |dir|
      fake_curl = File.join(dir, 'curl')
      File.write(fake_curl, <<~SH)
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
      File.chmod(0o755, fake_curl)

      original_path = ENV['PATH']
      ENV['PATH'] = "#{dir}#{File::PATH_SEPARATOR}#{original_path}"
      begin
        yield dir
      ensure
        ENV['PATH'] = original_path
      end
    end
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
      BuildHelpers.run_streaming({}, 'sh', '-c', 'echo hello')
    end

    assert_includes output, '[exec] sh -c echo hello'
    assert_includes output, 'hello'
  end

  def test_run_streaming_uses_explicit_log_display_value
    output = capture_stdout do
      BuildHelpers.run_streaming(
        {},
        'sh', '-c', 'exit 0',
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
          'sh', '-c', 'exit 3',
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
        BuildHelpers.run_streaming({}, 'sh', '-c', 'exit 1', log: '<redacted>')
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
end
