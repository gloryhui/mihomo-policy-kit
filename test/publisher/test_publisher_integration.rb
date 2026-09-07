# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# Publisher integration test（Issue #11 03/04/08 + Sol Review P0 两轮）。
# Linux 生产布局使用稳定 token symlink -> 共享 active/current symlink；Windows 无 symlink 权限时整组跳过。
# 额外覆盖 Sol 第二轮要求：promotion / rollback 的每个内部步骤之间真实读取
# public/sub/<token>/mihomo.yaml，断言始终存在、可读、内容只能是 old 或 new。
class ObservingRuntime < MPK::Publisher::Runtime
  def initialize(root)
    super
    @observer = nil
  end

  # 注入观察回调：每个原子 rename 前后都会调用。
  attr_accessor :observer

  def atomic_rename(source, target)
    @observer.call(source, target, :before) if @observer
    super.tap do
      @observer.call(source, target, :after) if @observer
    end
  end
end

class PublisherIntegrationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def require_symlink_support!
    probe = File.join(@dir, ".symlink-probe-#{Process.pid}")
    File.symlink(@dir, probe)
  rescue NotImplementedError, SystemCallError
    skip 'publisher shared-pointer integration requires filesystem symlink support (Linux production coverage)'
  ensure
    FileUtils.rm_f(probe) if probe && File.symlink?(probe)
  end

  def setup
    @dir = Dir.mktmpdir('mpk-pub-it-')
    require_symlink_support!
    @runtime = ObservingRuntime.new(File.join(@dir, 'runtime'))
    @pub = MPK::Publisher::Publisher.new(root: @runtime.root, runtime: @runtime)
    @pub.init!
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
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

  def current_build_yaml(build_id)
    File.join(@dir, 'runtime', 'builds', build_id, 'mihomo.yaml')
  end

  def test_first_publish_sets_current_with_no_previous
    @pub.publish(write_yaml('A', 443))
    assert_equal 1, @pub.status[:builds].length
    refute_nil @pub.status[:current]
    assert_nil @pub.status[:previous]
  end

  def test_second_publish_moves_old_to_previous
    first = @pub.publish(write_yaml('A', 443))
    second = @pub.publish(write_yaml('B', 8443))
    assert_equal second[:build_id], @pub.status[:current]
    assert_equal first[:build_id], @pub.status[:previous]
  end

  # 真实 filesystem 集成（Sol Review P0 #1 / #2）：
  # token URL 由 public/sub/<完整 token> 稳定 symlink 解析到共享 active/current，
  # promotion / rollback 后仍跟随；revoke 后该实际 URL 路径消失，其他 token 仍可读。
  def test_real_token_url_path_follows_current_rollback_and_revoke
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
    assert_equal File.binread(current_build_yaml(first[:build_id])), File.binread(url1)
    assert_equal File.binread(current_build_yaml(first[:build_id])), File.binread(url2)

    # promotion 到 B：两个 token 自动跟随新 current
    second = @pub.publish(write_yaml('B', 8443))
    assert_equal second[:build_id], @pub.status[:current]
    assert_equal File.binread(current_build_yaml(second[:build_id])), File.binread(url1)
    assert_equal File.binread(current_build_yaml(second[:build_id])), File.binread(url2)

    # rollback 回 A：token URL 路径仍可读并跟随 current
    @pub.rollback
    assert_equal first[:build_id], @pub.status[:current]
    assert_equal File.binread(current_build_yaml(first[:build_id])), File.binread(url1)
    assert_equal File.binread(current_build_yaml(first[:build_id])), File.binread(url2)

    # revoke phone：phone 的 URL 路径消失，laptop 仍可读
    @pub.revoke_token('phone')
    refute File.exist?(File.join(@dir, 'runtime', 'public', 'sub', t1[:token])),
           'revoked token public path must be removed'
    assert File.file?(url2), 'other token URL path must remain readable'
    assert_equal File.binread(current_build_yaml(first[:build_id])), File.binread(url2)
  end

  def test_revoke_one_token_does_not_affect_other
    @pub.publish(write_yaml('A', 443))
    t1 = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    t2 = @pub.create_token('laptop', public_base_url: 'https://sub.example.invalid')

    @pub.revoke_token('phone')

    assert_nil @pub.resolve_subscription(t1[:token]), 'revoked token should not resolve'
    refute_nil @pub.resolve_subscription(t2[:token]), 'other token still works'
    assert @pub.runtime.token_view?(t2[:token]), 'other token public view still present'
  end

  def test_token_view_is_stable_symlink_to_shared_current
    @pub.publish(write_yaml('A', 443))
    t1 = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')

    file = File.join(@dir, 'runtime', 'public', 'sub', t1[:token], 'mihomo.yaml')
    assert File.file?(file), 'token URL must resolve to a readable YAML file'
    assert File.symlink?(File.dirname(file)), 'token directory must be a stable symlink to shared active/current'
  end

  # Sol 第二轮 P0 核心：promote 全程每个内部步骤之间，token URL 恒存在、可读、
  # 内容只能是 old 或 new。
  def test_two_token_urls_switch_globally_at_the_shared_current_pointer
    first = @pub.publish(write_yaml('A', 443))
    phone = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    laptop = @pub.create_token('laptop', public_base_url: 'https://sub.example.invalid')
    urls = [phone, laptop].map { |token| File.join(@dir, 'runtime', 'public', 'sub', token[:token], 'mihomo.yaml') }
    old_content = File.binread(urls.first)
    candidate = write_yaml('C', 9443)
    new_content = File.binread(candidate)

    observed = []
    @runtime.observer = proc do |_source, _target, _phase|
      contents = urls.map do |url|
        flunk 'token URL must never disappear during promote' unless File.file?(url)
        File.binread(url)
      end
      observed << contents
      assert_equal contents.first, contents.last, 'all token URLs must share one current at every step'
      assert [old_content, new_content].include?(contents.first), 'content must be old or new complete build'
    end

    @pub.publish(candidate)
    refute_empty observed
    assert_equal [new_content, new_content], urls.map { |url| File.binread(url) }
  end

  def test_two_token_urls_switch_globally_during_rollback
    first = @pub.publish(write_yaml('A', 443))
    second = @pub.publish(write_yaml('B', 8443))
    phone = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    laptop = @pub.create_token('laptop', public_base_url: 'https://sub.example.invalid')
    urls = [phone, laptop].map { |token| File.join(@dir, 'runtime', 'public', 'sub', token[:token], 'mihomo.yaml') }
    old_content = File.binread(File.join(@dir, 'runtime', 'builds', second[:build_id], 'mihomo.yaml'))
    new_content = File.binread(File.join(@dir, 'runtime', 'builds', first[:build_id], 'mihomo.yaml'))

    observed = []
    @runtime.observer = proc do |_source, _target, _phase|
      contents = urls.map do |url|
        flunk 'token URL must never disappear during rollback' unless File.file?(url)
        File.binread(url)
      end
      observed << contents
      assert_equal contents.first, contents.last, 'all token URLs must share one current at every step'
      assert [old_content, new_content].include?(contents.first)
    end

    @pub.rollback
    refute_empty observed
    assert_equal [new_content, new_content], urls.map { |url| File.binread(url) }
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
