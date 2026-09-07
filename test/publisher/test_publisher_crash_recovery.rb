# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# 进程中途崩溃自愈回归测试（Sol Review P0 两轮；新原子性设计）。
# 新设计崩溃点只剩三类，全部可自愈且不破坏 good state：
#   - commit_build 中途崩溃：遗留 .build-staging-*，init! 清理，builds/ 不受污染
#   - 视图刷新滞后：active 已切到新 current，但某 token 视图仍是旧内容，
#     init!/下次操作 reconcile_public_views! 用当前 current 补齐（URL 恒可读旧或新）
#   - active tmp 残留：写 active 的临时文件在 rename 前崩溃，原 active 文件未动
class PublisherCrashRecoveryTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @dir = Dir.mktmpdir('mpk-crash-')
    @pub = MPK::Publisher::Publisher.new(root: File.join(@dir, 'runtime'))
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

  def runtime_root
    File.join(@dir, 'runtime')
  end

  def builds_dir
    File.join(runtime_root, 'builds')
  end

  def two_version_state
    a = @pub.publish(write_yaml('A', 443))
    b = @pub.publish(write_yaml('B', 8443))
    [a[:build_id], b[:build_id]]
  end

  def test_stale_build_staging_cleaned_on_next_init
    a_id, b_id = two_version_state

    # 模拟 commit_build 中途崩溃：留下 .build-staging-*
    stale = File.join(runtime_root, '.build-staging-deadbeef')
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, 'mihomo.yaml'), 'half-written')
    FileUtils.mkdir_p(stale + '-2')
    File.write(File.join(stale + '-2', 'metadata.json'), '{}')

    @pub.init!

    assert_empty Dir.glob(File.join(runtime_root, '.build-staging-*')),
                 'stale staging must be cleaned on init'
    # good state 不受影响
    assert_equal b_id, @pub.status[:current]
    assert_equal a_id, @pub.status[:previous]
  end

  def test_half_build_directory_ignored_after_crash
    a_id, b_id = two_version_state

    # 模拟极端情况：builds/ 里出现只有 YAML 没有 metadata 的半成品目录
    half_dir = File.join(builds_dir, '20260901T000000Z-deadbeefdead-ab12')
    FileUtils.mkdir_p(half_dir)
    File.write(File.join(half_dir, 'mihomo.yaml'), 'proxies: []\n')

    @pub.init!

    refute @pub.runtime.build_exists?(File.basename(half_dir))
    refute_includes @pub.status[:builds], File.basename(half_dir)
    assert_equal b_id, @pub.status[:current]
    assert_equal a_id, @pub.status[:previous]
  end

  def test_view_refresh_lag_self_heals_on_next_init
    a_id, b_id = two_version_state
    t = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    url = File.join(runtime_root, 'public', 'sub', t[:token], 'mihomo.yaml')

    # 模拟崩溃：active 已切到 A 的 state 但视图文件仍停留在 B
    # （手工把 active-state.json 改成 current=A，视图不动）
    File.write(File.join(runtime_root, 'active-state.json'),
               JSON.pretty_generate('current' => a_id, 'previous' => b_id))

    # 视图仍是 B 内容（滞后）
    assert_equal File.binread(File.join(builds_dir, b_id, 'mihomo.yaml')), File.binread(url)

    # 下一次 init! 自愈：视图刷新为 current=A
    @pub.init!
    assert_equal File.binread(File.join(builds_dir, a_id, 'mihomo.yaml')), File.binread(url)
  end

  def test_active_tmp_leftover_ignored
    a_id, b_id = two_version_state

    # 模拟写 active 的 tmp 文件在 rename 前崩溃：原 active 文件未动
    tmp = File.join(runtime_root, '.active-state.json.tmp-deadbeef')
    File.write(tmp, JSON.pretty_generate('current' => 'junk', 'previous' => nil))

    @pub.init!
    # tmp 不影响 active 解析；good state 不变
    assert_equal b_id, @pub.status[:current]
    assert_equal a_id, @pub.status[:previous]
    File.delete(tmp) if File.exist?(tmp)
  end

  def test_rollback_after_crash_lag_keeps_consistency
    a_id, b_id = two_version_state
    t = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    url = File.join(runtime_root, 'public', 'sub', t[:token], 'mihomo.yaml')

    # active 已 rollback（current=A, previous=B）但视图滞后仍是 B
    File.write(File.join(runtime_root, 'active-state.json'),
               JSON.pretty_generate('current' => a_id, 'previous' => b_id))

    # 用户触发下一次 rollback：入口 init! 先自愈视图，再执行 rollback
    result = @pub.rollback
    assert_equal b_id, result[:current]
    assert_equal a_id, result[:previous]
    # 视图最终 = 新 current(B)
    assert_equal File.binread(File.join(builds_dir, b_id, 'mihomo.yaml')), File.binread(url)
  end
end
