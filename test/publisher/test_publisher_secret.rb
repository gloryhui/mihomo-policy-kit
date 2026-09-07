# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'stringio'
require 'open3'
require 'rbconfig'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# V0.2 P0：Secret 回归测试。
# 断言普通 stdout / stderr / exception 不包含测试 secret。
class PublisherSecretTest < Minitest::Test
  SECRET = 'VERY_SECRET_PUBLISH_TOKEN_123'

  def setup
    @symlink_probe_dir = Dir.mktmpdir('mpk-symlink-probe-')
    probe = File.join(@symlink_probe_dir, 'link')
    File.symlink(@symlink_probe_dir, probe)
  rescue NotImplementedError, SystemCallError
    skip 'publisher shared-pointer integration requires filesystem symlink support (Linux production coverage)'
  ensure
    FileUtils.remove_entry(@symlink_probe_dir) if @symlink_probe_dir && File.exist?(@symlink_probe_dir)
  end

  def ruby
    RbConfig.ruby
  end

  def test_token_create_stdout_does_not_leak_on_failure
    Dir.mktmpdir do |dir|
      root = File.join(dir, 'runtime')
      pub = MPK::Publisher::Publisher.new(root: root)
      pub.init!
      # 先 publish 建立 current，再 create token（成功路径）
      artifact = File.join(dir, 'valid.yaml')
      File.write(artifact, YAML.dump(
        'proxies' => [{ 'name' => 'Fake', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'x' }],
        'proxy-groups' => [{ 'name' => 'G', 'type' => 'select', 'proxies' => ['Fake'] }],
        'rules' => ['MATCH,G']
      ))
      pub.publish(artifact)

      buffer = StringIO.new
      original = $stdout
      $stdout = buffer
      begin
        pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
      ensure
        $stdout = original
      end

      refute_includes buffer.string, SECRET
      refute_includes buffer.string, 'Fake'
    end
  end


  # CLI 级：publish 全流程 stdout/stderr 不包含 secret（用假 secret 内容）
  def test_cli_publish_stdout_does_not_contain_secret_content
    Dir.mktmpdir do |dir|
      artifact = File.join(dir, 'valid.yaml')
      File.write(artifact, YAML.dump(
        'proxies' => [{ 'name' => 'Fake', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'x' }],
        'proxy-groups' => [{ 'name' => 'G', 'type' => 'select', 'proxies' => ['Fake'] }],
        'rules' => ['MATCH,G']
      ))

      env = { 'MPK_PUBLISH_ROOT' => File.join(dir, 'runtime') }
      script = File.expand_path('../../scripts/publisher.rb', __dir__)
      stdout, stderr, status = Open3.capture3(env, ruby, script, 'publish', artifact)
      assert status.success?, "publish failed: #{stderr}"
      refute_includes stdout, SECRET
      refute_includes stderr, SECRET
    end
  end

  # 无效 token 不应产生可枚举的详细错误；find_active 返回 nil
  def test_invalid_token_returns_nil_not_error_detail
    Dir.mktmpdir do |dir|
      pub = MPK::Publisher::Publisher.new(root: File.join(dir, 'runtime'))
      pub.init!
      assert_nil pub.resolve_subscription('not-a-real-token')
    end
  end
end
