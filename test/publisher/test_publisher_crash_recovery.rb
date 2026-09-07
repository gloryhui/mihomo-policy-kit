# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# 进程中途崩溃自愈回归测试（Sol Review P0 两轮；新原子性设计）。
# 共享 current pointer 设计的崩溃回归：
#   - commit_build 中途崩溃：遗留 .build-staging-*，init! 清理，builds/ 不受污染
#   - current pointer rename 前后：所有 token 无需 reconcile 就天然同时解析旧/新 build
class PublisherCrashRecoveryTest < Minitest::Test
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
    @dir = Dir.mktmpdir('mpk-crash-')
    require_symlink_support!
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

  # 模拟切换前崩溃：current 仍指向 B，两个稳定 token 都天然解析 B；不需要 reconcile。
  def test_crash_before_current_pointer_switch_keeps_all_tokens_on_old_build
    a_id, b_id = two_version_state
    phone = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    laptop = @pub.create_token('laptop', public_base_url: 'https://sub.example.invalid')
    urls = [phone, laptop].map { |token| File.join(runtime_root, 'public', 'sub', token[:token], 'mihomo.yaml') }

    assert_equal [File.binread(File.join(builds_dir, b_id, 'mihomo.yaml'))] * 2, urls.map { |url| File.binread(url) }
    # “崩溃”发生在 final current rename 之前：无需 init!，共享 current 仍是 B。
    assert_equal b_id, @pub.runtime.current_build_id
    assert_equal [File.binread(urls[0])] * 2, urls.map { |url| File.binread(url) }
  end

  # 模拟 final current pointer rename 完成后立即崩溃：两个 token 共享同一 symlink，
  # 在不调用 init!/reconcile 的情况下已经同时解析 A。
  def test_crash_after_current_pointer_switch_keeps_all_tokens_on_new_build
    a_id, b_id = two_version_state
    phone = @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    laptop = @pub.create_token('laptop', public_base_url: 'https://sub.example.invalid')
    urls = [phone, laptop].map { |token| File.join(runtime_root, 'public', 'sub', token[:token], 'mihomo.yaml') }

    @pub.runtime.send(:replace_pointer, @pub.runtime.current_dir, a_id)

    assert_equal a_id, @pub.runtime.current_build_id
    assert_equal [File.binread(File.join(builds_dir, a_id, 'mihomo.yaml'))] * 2, urls.map { |url| File.binread(url) }
    refute_equal b_id, @pub.runtime.current_build_id
  end

end
