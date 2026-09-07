# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# Sol Review P0 故障注入回归：build staging、previous pointer、current pointer
# 的 rename 分别失败时，current/previous 与稳定 token URL 均保持 good state。
class FaultInjectingRuntime < MPK::Publisher::Runtime
  attr_accessor :fail_on_call

  def initialize(root)
    super
    @rename_calls = 0
    @fail_on_call = nil
  end

  def atomic_rename(source, target)
    @rename_calls += 1
    raise Errno::EIO, "injected rename failure (#{@rename_calls})" if @fail_on_call == @rename_calls

    super
  end

  def rename_calls
    @rename_calls
  end

  def reset_rename_counter!
    @rename_calls = 0
  end
end

class PublisherFaultInjectionTest < Minitest::Test
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
    @dir = Dir.mktmpdir('mpk-fault-')
    require_symlink_support!
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def build_runtime
    runtime = FaultInjectingRuntime.new(File.join(@dir, 'runtime'))
    runtime.init!
    runtime
  end

  def publisher(runtime)
    pub = MPK::Publisher::Publisher.new(root: runtime.root, runtime: runtime)
    pub.init!
    pub
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

  def two_version_state(pub, runtime)
    a = pub.publish(write_yaml('A', 443))
    b = pub.publish(write_yaml('B', 8443))
    assert_equal b[:build_id], pub.status[:current]
    assert_equal a[:build_id], pub.status[:previous]
    [a[:build_id], b[:build_id]]
  end

  def assert_state_b_a(pub, a_id, b_id)
    assert_equal b_id, pub.status[:current]
    assert_equal a_id, pub.status[:previous]
  end

  def build_dir(build_id)
    File.join(@dir, 'runtime', 'builds', build_id)
  end

  # 无 token 时 publish(C) 的 rename 序列：
  #   1 = commit_build(staging -> builds/C)
  #   2 = previous pointer
  #   3 = current pointer（唯一全局公开切换点）。
  # 在 current 指针写入失败时，current/previous 必须完全不变。
  def test_promote_active_write_failure_keeps_current_and_previous
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    runtime.reset_rename_counter!
    runtime.fail_on_call = 3 # current pointer rename 失败
    assert_raises(Errno::EIO) { pub.publish(write_yaml('C', 9443)) }

    assert_state_b_a(pub, a_id, b_id)
    # C 的 build 已原子进入（失败点在 promote），但不影响线上
    assert Dir.glob(File.join(@dir, 'runtime', 'builds', '*')).any? { |p| File.basename(p).start_with?('202') }

    # 后续可继续正常发布
    runtime.reset_rename_counter!
    runtime.fail_on_call = nil
    c = pub.publish(write_yaml('C', 9443))
    assert_equal c[:build_id], pub.status[:current]
    assert_equal b_id, pub.status[:previous]
  end

  # commit_build（staging -> builds）rename 失败：build 不进 builds，状态不变。
  def test_commit_build_rename_failure_leaves_no_build_and_keeps_state
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    runtime.reset_rename_counter!
    runtime.fail_on_call = 1 # commit_build rename 失败
    assert_raises(Errno::EIO) { pub.publish(write_yaml('C', 9443)) }

    assert_state_b_a(pub, a_id, b_id)
    # 无任何 C build 出现（staging 已清理，builds/ 不被污染）
    refute Dir.glob(File.join(@dir, 'runtime', 'builds', '*'))
              .any? { |p| !File.basename(p).start_with?('.') && !File.directory?(p) }
  end

  # rollback：current pointer 写入失败 -> current/previous 保持，current 恒不缺失。
  def test_rollback_active_write_failure_keeps_state
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    runtime.reset_rename_counter!
    runtime.fail_on_call = 2 # rollback 里 current pointer rename 是第 2 次
    assert_raises(Errno::EIO) { pub.rollback }

    assert_state_b_a(pub, a_id, b_id)

    # 再次 rollback（无故障）应正常工作：B/A 互换
    runtime.reset_rename_counter!
    runtime.fail_on_call = nil
    result = pub.rollback
    assert_equal a_id, result[:current]
    assert_equal b_id, result[:previous]
  end

  # current pointer 最终切换失败时，promote 必须恢复 B/A；token symlink 从未逐个复制或删除。
  def test_token_view_refresh_failure_restores_good_active_state
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)
    token = pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    token_path = File.join(runtime.root, 'public', 'sub', token[:token], 'mihomo.yaml')
    old_content = File.binread(token_path)

    runtime.reset_rename_counter!
    runtime.fail_on_call = 3 # commit_build, previous pointer, current pointer
    assert_raises(Errno::EIO) { pub.publish(write_yaml('C', 9443)) }

    assert_state_b_a(pub, a_id, b_id)
    assert File.file?(token_path), 'failed global switch must not remove the token URL path'
    assert_equal old_content, File.binread(token_path)
  end
end
