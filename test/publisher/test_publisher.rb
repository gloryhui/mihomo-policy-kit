# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'stringio'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/publisher'

class PublisherTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SECRET = 'VERY_SECRET_PUBLISH_TOKEN_123'

  def require_symlink_support!
    probe = File.join(@dir, ".symlink-probe-#{Process.pid}")
    File.symlink(@dir, probe)
  rescue NotImplementedError, SystemCallError
    skip 'publisher shared-pointer integration requires filesystem symlink support (Linux production coverage)'
  ensure
    FileUtils.rm_f(probe) if probe && File.symlink?(probe)
  end

  def setup
    @dir = Dir.mktmpdir('mpk-pub-')
    require_symlink_support!
    @pub = MPK::Publisher::Publisher.new(root: File.join(@dir, 'runtime'))
    @pub.init!
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def write_valid_yaml(name: 'Fake-US-01', extra_rules: [], proxies: nil)
    path = File.join(@dir, "#{name}.yaml")
    document = {
      'proxies' => proxies || [{ 'name' => 'Fake-US-01', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'fake-pass' }],
      'proxy-groups' => [{ 'name' => '🌍 全球节点', 'type' => 'select', 'proxies' => ['Fake-US-01'] }],
      'rules' => ['MATCH,🌍 全球节点'] + extra_rules
    }
    File.write(path, YAML.dump(document))
    path
  end

  def test_first_publish_establishes_current_no_previous
    artifact = write_valid_yaml
    result = @pub.publish(artifact)

    assert result[:published]
    refute_nil result[:build_id]
    assert_equal result[:build_id], @pub.status[:current]
    assert_nil @pub.status[:previous]
    assert File.file?(File.join(@dir, 'runtime', 'builds', result[:build_id], 'mihomo.yaml'))
    assert File.file?(File.join(@dir, 'runtime', 'builds', result[:build_id], 'metadata.json'))
  end

  def test_second_publish_sets_previous_to_first
    a = write_valid_yaml(name: 'a', proxies: [{ 'name' => 'A', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'x' }])
    b = write_valid_yaml(name: 'b', proxies: [{ 'name' => 'B', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 8443, 'cipher' => 'aes-128-gcm', 'password' => 'y' }])

    first = @pub.publish(a)
    second = @pub.publish(b)

    assert_equal second[:build_id], @pub.status[:current]
    assert_equal first[:build_id], @pub.status[:previous]
    refute_equal first[:build_id], second[:build_id]
  end

  def test_publish_same_content_is_idempotent
    artifact = write_valid_yaml
    first = @pub.publish(artifact)
    builds_after_first = @pub.status[:builds].length

    second = @pub.publish(artifact)

    refute second[:published], 'identical content should not create a new build'
    assert_equal first[:build_id], second[:build_id]
    assert_equal builds_after_first, @pub.status[:builds].length
    assert_equal first[:build_id], @pub.status[:current]
  end

  def test_rollback_swaps_current_and_previous
    a = write_valid_yaml(name: 'a', proxies: [{ 'name' => 'A', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'x' }])
    b = write_valid_yaml(name: 'b', proxies: [{ 'name' => 'B', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 8443, 'cipher' => 'aes-128-gcm', 'password' => 'y' }])
    first = @pub.publish(a)
    second = @pub.publish(b)

    result = @pub.rollback
    assert_equal first[:build_id], result[:current]
    assert_equal second[:build_id], result[:previous]

    # 再次 rollback 切回
    result2 = @pub.rollback
    assert_equal second[:build_id], result2[:current]
    assert_equal first[:build_id], result2[:previous]
  end

  def test_publish_previous_content_reuses_build_not_new_version
    a = write_valid_yaml(name: 'a', proxies: [{ 'name' => 'A', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'x' }])
    b = write_valid_yaml(name: 'b', proxies: [{ 'name' => 'B', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 8443, 'cipher' => 'aes-128-gcm', 'password' => 'y' }])
    first = @pub.publish(a)
    @pub.publish(b)
    builds_before = @pub.status[:builds].length

    # 发布回 previous（A）的内容：应复用 first build 作为 current，不新建版本
    result = @pub.publish(a)
    refute result[:published], 're-publishing previous content should not create a build'
    assert_equal first[:build_id], result[:build_id]
    assert_equal builds_before, @pub.status[:builds].length
    assert_equal first[:build_id], @pub.status[:current]
  end

  def test_rollback_without_previous_raises
    artifact = write_valid_yaml
    @pub.publish(artifact)
    assert_raises(MPK::Error) { @pub.rollback }
  end

  def test_rollback_does_not_modify_builds
    a = write_valid_yaml(name: 'a', proxies: [{ 'name' => 'A', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'x' }])
    b = write_valid_yaml(name: 'b', proxies: [{ 'name' => 'B', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 8443, 'cipher' => 'aes-128-gcm', 'password' => 'y' }])
    first = @pub.publish(a)
    second = @pub.publish(b)

    build_a_content = File.binread(File.join(@dir, 'runtime', 'builds', first[:build_id], 'mihomo.yaml'))
    build_b_content = File.binread(File.join(@dir, 'runtime', 'builds', second[:build_id], 'mihomo.yaml'))

    @pub.rollback

    assert_equal build_a_content, File.binread(File.join(@dir, 'runtime', 'builds', first[:build_id], 'mihomo.yaml'))
    assert_equal build_b_content, File.binread(File.join(@dir, 'runtime', 'builds', second[:build_id], 'mihomo.yaml'))
  end

  def test_failed_publish_keeps_current_unchanged
    good = write_valid_yaml
    @pub.publish(good)
    current_before = @pub.status[:current]

    # 空文件 -> 校验失败
    bad = File.join(@dir, 'bad.yaml')
    File.write(bad, '')

    assert_raises(MPK::Error) { @pub.publish(bad) }
    assert_equal current_before, @pub.status[:current]
  end

  def test_publish_invalid_yaml_keeps_current
    good = write_valid_yaml
    @pub.publish(good)
    current_before = @pub.status[:current]

    bad = File.join(@dir, 'bad.yaml')
    File.write(bad, "proxies: [\n  broken")

    assert_raises(MPK::Error) { @pub.publish(bad) }
    assert_equal current_before, @pub.status[:current]
  end

  def test_publish_no_proxies_rejected
    good = write_valid_yaml
    @pub.publish(good)
    current_before = @pub.status[:current]

    bad = File.join(@dir, 'bad.yaml')
    File.write(bad, YAML.dump({ 'proxies' => [], 'proxy-groups' => [{ 'name' => 'G', 'type' => 'select', 'proxies' => [] }], 'rules' => ['MATCH,G'] }))

    assert_raises(MPK::Error) { @pub.publish(bad) }
    assert_equal current_before, @pub.status[:current]
  end

  def test_status_reports_current_previous_builds
    a = write_valid_yaml(name: 'a', proxies: [{ 'name' => 'A', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'x' }])
    b = write_valid_yaml(name: 'b', proxies: [{ 'name' => 'B', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 8443, 'cipher' => 'aes-128-gcm', 'password' => 'y' }])
    @pub.publish(a)
    @pub.publish(b)

    status = @pub.status
    assert_equal 2, status[:builds].length
    assert_equal @pub.status[:current], status[:current]
    assert_equal @pub.status[:previous], status[:previous]
  end

  def test_metadata_contains_no_secrets
    artifact = write_valid_yaml
    @pub.publish(artifact)
    status = @pub.status
    metadata = @pub.runtime.build_metadata(status[:current])

    serialized = metadata.to_s
    refute_includes serialized, SECRET
    refute_includes serialized, 'fake-pass'
  end

  def test_publish_output_never_contains_secret
    artifact = write_valid_yaml
    output = capture_stdout { @pub.publish(artifact) }
    refute_includes output, SECRET
    refute_includes output, 'fake-pass'
  end

  def test_rollback_output_never_contains_secret
    a = write_valid_yaml(name: 'a', proxies: [{ 'name' => 'A', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'x' }])
    b = write_valid_yaml(name: 'b', proxies: [{ 'name' => 'B', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 8443, 'cipher' => 'aes-128-gcm', 'password' => 'y' }])
    @pub.publish(a)
    @pub.publish(b)
    output = capture_stdout { @pub.rollback }
    refute_includes output, SECRET
  end

  def test_token_create_failure_rolls_back_record
    # 尚无 current build 时，create_token 应报错且不留孤儿 token 记录。
    # （共享 current 的 symlink 布局中，失败发生在无 current 等场景）
    error = assert_raises(MPK::Error) do
      @pub.create_token('phone', public_base_url: 'https://sub.example.invalid')
    end
    refute_nil error
    assert_empty @pub.list_tokens, 'failed create must not leave orphan tokens'
  end


  def capture_stdout
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    yield
    buffer.string
  ensure
    $stdout = original
  end
end
