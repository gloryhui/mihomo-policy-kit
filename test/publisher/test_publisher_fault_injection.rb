# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# Sol Review P0 故障注入回归测试：
#   - publish promotion 最终 rename 失败时，current/previous 必须与操作前完全一致
#     （B current / A previous 不被破坏，previous 不丢失）
#   - rollback 中途 rename 失败时，current/previous 保持操作前状态，current 不缺失
# 通过子类 Runtime 在第 N 次 atomic_rename 注入失败实现（纯目录 rename，跨平台可跑）。
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

  # 在注入故障前清零计数，使 fail_on_call 相对于下一次 promote!/rollback!。
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

  # 建立 A -> current、B -> current（A 为 previous）的双版本状态。
  def two_version_state(pub, runtime)
    a = pub.publish(write_yaml('A', 443))
    b = pub.publish(write_yaml('B', 8443))
    assert_equal b[:build_id], pub.status[:current]
    assert_equal a[:build_id], pub.status[:previous]
    [a[:build_id], b[:build_id]]
  end

  # 断言 current=B、previous=A，且两个视图目录内容/metadata 都可用。
  def assert_state_b_a(pub, a_id, b_id)
    assert_equal b_id, pub.status[:current]
    assert_equal a_id, pub.status[:previous]
    assert File.file?(File.join(@dir, 'runtime', 'current', 'mihomo.yaml'))
    assert File.file?(File.join(@dir, 'runtime', 'previous', 'mihomo.yaml'))
  end

  def test_promote_final_rename_failure_keeps_current_and_previous
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    # promote 的第 3 次 rename（新视图 -> current）失败：
    #   B=current/A=previous 时发布 C，模拟最终 promotion rename 失败。
    runtime.reset_rename_counter!
    runtime.fail_on_call = 3
    error = assert_raises(Errno::EIO) { pub.publish(write_yaml('C', 9443)) }
    refute_nil error

    # 失败后仍严格保持 current=B、previous=A（previous 不丢失）
    assert_state_b_a(pub, a_id, b_id)

    # 后续可继续正常发布（故障只注入一次）
    runtime.reset_rename_counter!
    runtime.fail_on_call = nil
    c = pub.publish(write_yaml('C', 9443))
    assert_equal c[:build_id], pub.status[:current]
    assert_equal b_id, pub.status[:previous]
  end

  def test_promote_first_rename_failure_keeps_current_and_previous
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    # promote 的第 1 次 rename（previous -> backup journal）失败：
    # 任何一步都不得移动/破坏 previous。
    runtime.reset_rename_counter!
    runtime.fail_on_call = 1
    assert_raises(Errno::EIO) { pub.publish(write_yaml('C', 9443)) }
    assert_state_b_a(pub, a_id, b_id)
  end

  def test_promote_second_rename_failure_keeps_current_and_previous
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    # promote 的第 2 次 rename（current -> previous）失败：
    runtime.reset_rename_counter!
    runtime.fail_on_call = 2
    assert_raises(Errno::EIO) { pub.publish(write_yaml('C', 9443)) }
    assert_state_b_a(pub, a_id, b_id)
  end

  def test_rollback_mid_failure_keeps_state_current_never_missing
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    # rollback 交换的第 3 次 rename（backup -> current，即完成互换那步）失败：
    # 旧 current（B）此时已被移入 previous 槽，失败恢复必须把它放回 current。
    runtime.reset_rename_counter!
    runtime.fail_on_call = 3
    assert_raises(Errno::EIO) { pub.rollback }
    assert_state_b_a(pub, a_id, b_id)
    assert File.file?(File.join(@dir, 'runtime', 'current', 'mihomo.yaml')),
           'current must never be missing after a failed rollback'

    # 再次 rollback（无故障）应正常工作：B/A 互换
    runtime.reset_rename_counter!
    runtime.fail_on_call = nil
    result = pub.rollback
    assert_equal a_id, result[:current]
    assert_equal b_id, result[:previous]
  end

  def test_rollback_second_rename_failure_keeps_state_current_never_missing
    runtime = build_runtime
    pub = publisher(runtime)
    a_id, b_id = two_version_state(pub, runtime)

    # rollback 交换的第 2 次 rename（current -> previous）失败：
    runtime.reset_rename_counter!
    runtime.fail_on_call = 2
    assert_raises(Errno::EIO) { pub.rollback }
    assert_state_b_a(pub, a_id, b_id)
    assert File.file?(File.join(@dir, 'runtime', 'current', 'mihomo.yaml'))
  end
end
