# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# 进程中途崩溃自愈回归测试（Sol Review P0 / Issue #11 03）：
# 直接构造“promote / rollback 在中途崩溃后遗留的 journal 备份状态”，
# 再调用下一个操作，断言自愈把 current/previous 恢复到操作前一致状态，
# current 永远可读（指向完整 build），previous 不丢失。
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

  # 建立 A=previous、B=current 的双版本状态。
  def two_version_state
    a = @pub.publish(write_yaml('A', 443))
    b = @pub.publish(write_yaml('B', 8443))
    [a[:build_id], b[:build_id]]
  end

  def move(from, to)
    File.rename(File.join(runtime_root, from), File.join(runtime_root, to))
  end

  def test_recover_rollback_crash_after_step2_completes_swap
    a_id, b_id = two_version_state
    # 模拟 rollback 第 2 步（current -> previous）后崩溃：
    # previous 槽 = 旧 B(backup 前)… 构造：把 previous(A) 移到 journal，
    # 再把 current(B) 移到 previous，current 槽空。
    move('previous', '.rollback-backup-crashed')
    move('current', 'previous')

    # 下一个操作触发自愈：journal -> current，完成互换
    @pub.status
    assert_equal a_id, @pub.status[:current]
    assert_equal b_id, @pub.status[:previous]
    assert File.file?(File.join(runtime_root, 'current', 'mihomo.yaml'))
  end

  def test_recover_rollback_crash_after_step1_undo
    a_id, b_id = two_version_state
    # 模拟 rollback 第 1 步（previous -> journal）后崩溃：current 槽仍为 B
    move('previous', '.rollback-backup-crashed')

    @pub.status
    assert_equal b_id, @pub.status[:current]
    assert_equal a_id, @pub.status[:previous]
    assert File.file?(File.join(runtime_root, 'current', 'mihomo.yaml'))
  end

  def test_recover_promote_crash_after_step1_undo
    a_id, b_id = two_version_state
    # 模拟 promote 第 1 步（previous -> journal）后崩溃：current 仍 B，previous 槽空
    move('previous', '.prev-backup-crashed')

    @pub.status
    assert_equal b_id, @pub.status[:current]
    assert_equal a_id, @pub.status[:previous]
    assert File.file?(File.join(runtime_root, 'current', 'mihomo.yaml'))
  end

  def test_recover_promote_crash_after_step2_restores_original
    a_id, b_id = two_version_state
    # 模拟 promote 第 2 步（current -> previous）后崩溃：
    # previous 槽 = 旧 B；backup 槽 = 旧 A；current 槽空
    move('previous', '.prev-backup-crashed')
    move('current', 'previous')

    @pub.status
    # 恢复为操作前状态：current=B、previous=A
    assert_equal b_id, @pub.status[:current]
    assert_equal a_id, @pub.status[:previous]
    assert File.file?(File.join(runtime_root, 'current', 'mihomo.yaml'))
  end
end
