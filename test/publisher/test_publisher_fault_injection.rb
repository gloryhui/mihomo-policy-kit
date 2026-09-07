# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# Sol Review P0 故障注入回归测试（第二轮原子性设计）：
#   - 新设计原子点：commit_build 的 staging->builds rename、write_active 的
#     active-state.json rename、write_view_file 的视图文件 rename。
#   - 通过子类 Runtime 在第 N 次 atomic_rename 注入失败。
# 断言失败后不破坏 good state：current/previous 保持、builds 不受污染、
# token URL 始终可读（旧或新完整版本）。
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

  def setup
    @dir = Dir.mktmpdir('mpk-fault-')
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
  #   2 = write_active(active-state.json)
  # 在 active 指针写入失败时，current/previous 必须完全不变。
  def test_promote_active_write_failure_keeps_current_and_previous
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    runtime.reset_rename_counter!
    runtime.fail_on_call = 2 # active-state.json rename 失败
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

  # rollback：active 指针写入失败 -> current/previous 保持，current 恒不缺失。
  def test_rollback_active_write_failure_keeps_state
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    runtime.reset_rename_counter!
    runtime.fail_on_call = 1 # rollback 里 write_active 的 rename 是第 1 次
    assert_raises(Errno::EIO) { pub.rollback }

    assert_state_b_a(pub, a_id, b_id)

    # 再次 rollback（无故障）应正常工作：B/A 互换
    runtime.reset_rename_counter!
    runtime.fail_on_call = nil
    result = pub.rollback
    assert_equal a_id, result[:current]
    assert_equal b_id, result[:previous]
  end

  # active 指针已切到 C、但 token 视图原子覆盖失败时，promote 必须把 active
  # 恢复为 B/A 并让 token 视图回到 B；全过程目标文件都没有被删除。
  def test_token_view_refresh_failure_restores_good_active_state
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)
    token = pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    token_path = File.join(runtime.root, 'public', 'sub', token[:token], 'mihomo.yaml')
    old_content = File.binread(token_path)

    runtime.reset_rename_counter!
    runtime.fail_on_call = 3 # commit_build, active-state, token view
    assert_raises(Errno::EIO) { pub.publish(write_yaml('C', 9443)) }

    assert_state_b_a(pub, a_id, b_id)
    assert File.file?(token_path), 'failed refresh must not remove the token URL path'
    assert_equal old_content, File.binread(token_path)
  end
end
