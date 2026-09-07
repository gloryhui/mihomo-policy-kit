# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'fileutils'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

# Sol 第二轮 Review P0#2 回归测试：
#   build 必须 staging 后原子进入 builds/，崩溃最多遗留 staging / 半成品目录，
#   不得被当成有效 build。
class BuildCommitObservingRuntime < MPK::Publisher::Runtime
  attr_reader :commit_observations

  def initialize(root)
    super
    @commit_observations = []
  end

  def atomic_rename(source, target)
    is_build_commit = File.dirname(target) == builds_dir &&
                      File.basename(source).start_with?('.build-staging-')
    @commit_observations << [:before, File.exist?(target), build_exists?(File.basename(target))] if is_build_commit
    super.tap do
      @commit_observations << [:after, File.exist?(target), build_exists?(File.basename(target))] if is_build_commit
    end
  end
end

class PublisherStagingAtomicityTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @dir = Dir.mktmpdir('mpk-stage-')
    @runtime = BuildCommitObservingRuntime.new(File.join(@dir, 'runtime'))
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

  def runtime_root
    File.join(@dir, 'runtime')
  end

  def builds_dir
    File.join(runtime_root, 'builds')
  end

  # 构造“写完 YAML 但 metadata 未完成即崩溃”的残留 build 目录。
  def leave_half_build(build_id, yaml: 'proxies: []\n')
    dir = File.join(builds_dir, build_id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'mihomo.yaml'), yaml)
    dir
  end

  def test_half_build_not_listed_not_promotable
    half = '20260901T000000Z-aaaaaaaaaaaa-abcd'
    leave_half_build(half)

    @pub.init!
    refute_includes @pub.status[:builds], half, 'half build must not appear in list_builds'
    refute @pub.runtime.build_exists?(half)
    assert_raises(MPK::Error) { @pub.runtime.promote!(half) }
  end

  def test_yaml_plus_incomplete_metadata_is_not_a_legal_build
    half = '20260901T000000Z-eeeeeeeeeeee-ef01'
    dir = leave_half_build(half)
    File.write(File.join(dir, 'metadata.json'), '{}')

    @pub.init!
    refute @pub.runtime.build_exists?(half)
    refute_includes @pub.status[:builds], half
    assert_raises(MPK::Error) { @pub.runtime.promote!(half) }
  end

  def test_half_build_not_reused_by_sha256
    # 先正常发布 A
    artifact_a = write_yaml('A', 443)
    a = @pub.publish(artifact_a)
    content_a = File.binread(artifact_a)
    # 手工构造一个“同内容 A 但缺 metadata”的半成品 build 目录
    half = '20260901T000000Z-bbbbbbbbbbbb-cdef'
    leave_half_build(half, yaml: content_a)

    @pub.init!
    refute @pub.runtime.build_exists?(half)

    # 再次发布同内容 A：幂等应复用完整 build A，而不是半成品 half
    again = @pub.publish(artifact_a)
    assert_equal a[:build_id], again[:build_id]
    assert_equal a[:build_id], @pub.status[:current]
  end

  def test_metadata_sha256_mismatch_is_not_a_legal_build
    half = '20260901T000000Z-ffffffffffff-f012'
    dir = leave_half_build(half, yaml: 'proxies: []\n')
    File.write(File.join(dir, 'metadata.json'), JSON.generate(
      'build_id' => half,
      'sha256' => '0' * 64
    ))

    refute @pub.runtime.build_exists?(half)
    refute_includes @pub.status[:builds], half
    assert_raises(MPK::Error) { @pub.runtime.promote!(half) }
  end

  def test_stale_staging_cleaned_on_init
    # 构造崩溃遗留的 staging 目录（隐藏命名，不属于 builds）
    stale = File.join(runtime_root, '.build-staging-deadbeef')
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, 'mihomo.yaml'), 'junk')

    @pub.init!
    refute File.exist?(stale), 'stale staging must be cleaned on init'
    assert_empty Dir.glob(File.join(runtime_root, '.build-staging-*'))
  end

  def test_normal_publish_appears_only_after_atomic_commit
    # 发布前 builds/ 为空；commit rename 前目标目录不存在，rename 后首次出现时已完整合法。
    assert_empty @pub.status[:builds]
    @runtime.commit_observations.clear

    result = @pub.publish(write_yaml('A', 443))
    assert result[:published]
    assert_includes @pub.status[:builds], result[:build_id]
    assert_equal [[:before, false, false], [:after, true, true]], @runtime.commit_observations
    # build 目录完整
    assert File.file?(File.join(builds_dir, result[:build_id], 'mihomo.yaml'))
    assert File.file?(File.join(builds_dir, result[:build_id], 'metadata.json'))
    # 无 staging 残留
    assert_empty Dir.glob(File.join(runtime_root, '.build-staging-*'))
  end

  def test_half_build_does_not_pollute_next_publish
    leave_half_build('20260901T000000Z-cccccccccccc-1234')
    @pub.init!

    result = @pub.publish(write_yaml('A', 443))
    assert result[:published]
    # 正常 build 进入且列表只有它（半成品被忽略）
    assert_equal [result[:build_id]], @pub.status[:builds]
  end
end
