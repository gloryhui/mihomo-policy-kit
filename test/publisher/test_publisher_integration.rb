# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# Publisher integration test（Issue #11 03/04/08 + Sol Review P0 两轮）。
# 新布局不再依赖 symlink：token 公开视图是真实文件 public/sub/<token>/mihomo.yaml，
# 因此这些断言在 Windows / Linux 均可运行。
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

  def setup
    @dir = Dir.mktmpdir('mpk-pub-it-')
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
  # token URL 是 public/sub/<完整 token>/mihomo.yaml 真实文件，跟随 current，
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

  def test_token_view_is_real_file_not_symlink
    @pub.publish(write_yaml('A', 443))
    t1 = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')

    file = File.join(@dir, 'runtime', 'public', 'sub', t1[:token], 'mihomo.yaml')
    assert File.file?(file), 'token view should be a regular readable file'
    refute File.symlink?(file), 'token view should not rely on symlink'
  end

  # Sol 第二轮 P0 核心：promote 全程每个内部步骤之间，token URL 恒存在、可读、
  # 内容只能是 old 或 new。
  def test_token_url_always_readable_old_or_new_during_promote
    @pub.publish(write_yaml('A', 443))
    t1 = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    url = File.join(@dir, 'runtime', 'public', 'sub', t1[:token], 'mihomo.yaml')

    @pub.publish(write_yaml('B', 8443))
    old_content = File.binread(url)
    candidate = write_yaml('C', 9443)
    candidate_content = File.binread(candidate)

    # 观察每个内部步骤之间（在 Runtime 每次写文件前回调检查）
    observed = []
    @runtime.observer = proc do |_source, _target, _phase|
      if File.file?(url)
        content = File.binread(url)
        observed << content
        assert [old_content, candidate_content].include?(content),
               "token content must be old or new, got #{content.inspect}"
      else
        observed << :missing
        flunk 'token URL must never disappear during promote'
      end
    end

    @pub.publish(candidate)
    refute_empty observed, 'observer must run at every internal atomic switch step'
    final_content = File.binread(current_build_yaml(@pub.status[:current]))
    observed << File.binread(url)
    assert_equal final_content, observed.last
  end

  # 观察式：rollback 全程每个内部步骤之间 token URL 恒可读 old/new。
  def test_token_url_always_readable_old_or_new_during_rollback
    first = @pub.publish(write_yaml('A', 443))
    @pub.publish(write_yaml('B', 8443))
    t1 = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    url = File.join(@dir, 'runtime', 'public', 'sub', t1[:token], 'mihomo.yaml')

    cur_content = File.binread(url) # B
    prev_content = File.binread(current_build_yaml(first[:build_id])) # A

    observed = []
    @runtime.observer = proc do |_source, _target, _phase|
      if File.file?(url)
        content = File.binread(url)
        observed << content
        assert [cur_content, prev_content].include?(content),
               "rollback token content must be old current or previous, got #{content.inspect}"
      else
        observed << :missing
        flunk 'token URL must never disappear during rollback'
      end
    end

    @pub.rollback
    refute_empty observed, 'observer must run at every internal atomic switch step'
    assert_equal first[:build_id], @pub.status[:current]
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
