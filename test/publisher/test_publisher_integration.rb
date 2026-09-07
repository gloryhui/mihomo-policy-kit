# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# Publisher Linux integration test（Issue #11 03/04/08 + Sol Review P0）。
# 覆盖真实 symlink / atomic rename 行为、多 token 跟随 current、revoke 隔离。
# Windows 上创建 symlink 需要权限，这里跳过 symlink 相关断言但保留纯逻辑检查。
class PublisherIntegrationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @dir = Dir.mktmpdir('mpk-pub-it-')
    @pub = MPK::Publisher::Publisher.new(root: File.join(@dir, 'runtime'))
    @pub.init!
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def symlink_supported?
    return @symlink_supported unless @symlink_supported.nil?

    begin
      probe = File.join(@dir, 'probe-link')
      File.symlink(@dir, probe)
      @symlink_supported = true
    rescue SystemCallError, NotImplementedError
      @symlink_supported = false
    end
  end

  def write_yaml(name, port)
    path = File.join(@dir, "#{name}.yaml")
    File.write(path, YAML.dump(
      'proxies' => [{ 'name' => name, 'type' => 'ss', 'server' => '127.0.0.1', 'port' => port, 'cipher' => 'aes-128-gcm', 'password' => 'x' }],
      'proxy-groups' => [{ 'name' => 'G', 'type' => 'select', 'proxies' => [name] }],
      'rules' => ['MATCH,G']
    ))
    path
  end

  def current_yaml_path
    File.join(@dir, 'runtime', 'current', 'mihomo.yaml')
  end

  def test_first_publish_sets_current_with_no_previous
    @pub.publish(write_yaml('A', 443))
    assert_equal 1, @pub.status[:builds].length
    refute_nil @pub.status[:current]
    assert_nil @pub.status[:previous]
    assert File.file?(current_yaml_path)
  end

  def test_second_publish_moves_old_to_previous
    first = @pub.publish(write_yaml('A', 443))
    second = @pub.publish(write_yaml('B', 8443))
    assert_equal second[:build_id], @pub.status[:current]
    assert_equal first[:build_id], @pub.status[:previous]
  end

  # 真实 filesystem 集成（Sol Review P0 #1）：
  # 创建 token 后，public/sub/<完整 token>/mihomo.yaml 必须真实可读，且内容跟随 current；
  # promotion / rollback 后仍跟随；revoke 后该实际 URL 路径消失，其他 token 仍可读。
  def test_real_token_url_path_follows_current_rollback_and_revoke
    skip 'symlink unsupported on this platform' unless symlink_supported?

    first = @pub.publish(write_yaml('A', 443))
    t1 = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    t2 = @pub.create_token('laptop', public_base_url: 'https://sub.example.invalid')

    url1 = File.join(@dir, 'runtime', 'public', 'sub', t1[:token], 'mihomo.yaml')
    url2 = File.join(@dir, 'runtime', 'public', 'sub', t2[:token], 'mihomo.yaml')

    # token 目录 = 客户端 URL 中的完整高熵 token
    assert File.file?(url1), 'token URL path must exist for static Nginx'
    assert File.file?(url2)
    refute_equal t1[:token], MPK::Publisher::TokenStore.fingerprint(t1[:token]),
                 'public path must use the full token, not the short fingerprint'

    # 内容跟随 current（A）
    assert_equal File.binread(current_yaml_path), File.binread(url1)
    assert_equal File.binread(current_yaml_path), File.binread(url2)

    # promotion 到 B：两个 token 自动跟随新 current
    second = @pub.publish(write_yaml('B', 8443))
    assert_equal second[:build_id], @pub.status[:current]
    assert_equal File.binread(current_yaml_path), File.binread(url1)
    assert_equal File.binread(current_yaml_path), File.binread(url2)

    # rollback 回 A：token URL 路径仍可读并跟随 current
    @pub.rollback
    assert_equal first[:build_id], @pub.status[:current]
    assert_equal File.binread(current_yaml_path), File.binread(url1)
    assert_equal File.binread(current_yaml_path), File.binread(url2)

    # revoke phone：phone 的 URL 路径消失，laptop 仍可读
    @pub.revoke_token('phone')
    refute File.exist?(File.join(@dir, 'runtime', 'public', 'sub', t1[:token])),
           'revoked token public path must be removed'
    assert File.file?(url2), 'other token URL path must remain readable'
    assert_equal File.binread(current_yaml_path), File.binread(url2)
  end

  def test_revoke_one_token_does_not_affect_other
    skip 'symlink unsupported on this platform' unless symlink_supported?

    @pub.publish(write_yaml('A', 443))
    t1 = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    t2 = @pub.create_token('laptop', public_base_url: 'https://sub.example.invalid')

    @pub.revoke_token('phone')

    assert_nil @pub.resolve_subscription(t1[:token]), 'revoked token should not resolve'
    refute_nil @pub.resolve_subscription(t2[:token]), 'other token still works'
    assert @pub.runtime.token_view?(t2[:token]), 'other token public view still present'
  end

  def test_token_view_is_symlink_to_current
    skip 'symlink unsupported on this platform' unless symlink_supported?

    @pub.publish(write_yaml('A', 443))
    t1 = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')

    link = File.join(@dir, 'runtime', 'public', 'sub', t1[:token])
    assert File.symlink?(link), 'token view should be a symlink'
    target = File.realpath(link)
    current_real = File.realpath(File.join(@dir, 'runtime', 'current'))
    assert_equal current_real, target
  end

  def test_builds_are_immutable_after_publish
    first = @pub.publish(write_yaml('A', 443))
    second = @pub.publish(write_yaml('B', 8443))

    build_a = File.join(@dir, 'runtime', 'builds', first[:build_id], 'mihomo.yaml')
    before = File.binread(build_a)
    # 再次发布相同内容 B 或 rollback 都不应修改 builds/A
    @pub.rollback
    @pub.publish(write_yaml('B', 8443))
    assert_equal before, File.binread(build_a)
  end

  def test_promotion_failure_keeps_current_valid
    first = @pub.publish(write_yaml('A', 443))
    good_current = @pub.status[:current]

    bad = File.join(@dir, 'bad.yaml')
    File.write(bad, '') # 空文件 -> validate 失败
    assert_raises(MPK::Error) { @pub.publish(bad) }
    assert_equal good_current, @pub.status[:current]
    assert_equal first[:build_id], good_current
  end
end
