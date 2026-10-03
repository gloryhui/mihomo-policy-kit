# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/services/control_plane'

class ControlPlaneTest < Minitest::Test
  KEY = 'a1' * 32

  def setup
    @dir = Dir.mktmpdir('mpk-control-中文-')
    @db = MPK::Services::Database.open(File.join(@dir, 'mpk.db'))
    @crypto = MPK::Services::Crypto.new(KEY)
    @control = MPK::Services::ControlPlane.new(db: @db, data_root: @dir, crypto: @crypto)
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@dir)
  end

  def proxy(name = '香港01', port = 8001)
    { 'name' => name, 'type' => 'ss', 'server' => '127.0.0.1', 'port' => port,
      'cipher' => 'aes-128-gcm', 'password' => 'VERY_SECRET_NODE_PASSWORD', 'client-fingerprint' => 'chrome' }
  end

  def add_source(name: 'fixture', proxies: [proxy], **settings)
    @control.sources.save({ 'name' => name, 'input_kind' => 'inline', 'content' => YAML.dump('proxies' => proxies) }.merge(settings.transform_keys(&:to_s)))
  end

  def refresh(source)
    @control.sources.refresh(source[:id])
  end

  def add_profile(sources, **attrs)
    @control.save_profile({ 'name' => 'fixture profile', 'provider' => 'acl4ssr', 'source_ids' => sources.map { |s| s[:id] } }.merge(attrs.transform_keys(&:to_s)))
  end

  def test_versioned_migration_and_sqlite_settings
    assert_equal 1, @db[:schema_info].get(:version)
    assert_equal 1, @db.fetch('PRAGMA foreign_keys').get(:foreign_keys)
    assert_equal 'wal', @db.fetch('PRAGMA journal_mode').get(:journal_mode)
    assert_equal 5000, @db.fetch('PRAGMA busy_timeout').get(:timeout)
    MPK::Services::Database.open(File.join(@dir, 'mpk.db')).disconnect
    assert_equal 1, @db[:schema_info].get(:version)
  end

  def test_aes_gcm_roundtrip_wrong_key_missing_key_and_tamper
    secret = @crypto.encrypt('https://example.invalid/VERY_SECRET_URL_TOKEN')
    assert_equal 'https://example.invalid/VERY_SECRET_URL_TOKEN', @crypto.decrypt(secret)
    wrong = MPK::Services::Crypto.new('b2' * 32)
    assert_raises(MPK::Services::Failure) { wrong.decrypt(secret) }
    assert_raises(MPK::Services::Failure) { MPK::Services::Crypto.new(nil).encrypt('secret') }
    assert_raises(MPK::Services::Failure) { MPK::Services::Crypto.new('invalid').encrypt('secret') }
    assert_raises(MPK::Services::Failure) { @crypto.decrypt(secret.merge(tag: Base64.strict_encode64('z' * 16))) }
    refute_includes secret.values.join, 'VERY_SECRET'
  end

  def test_source_secrets_are_encrypted_and_never_in_dto
    source = @control.sources.save({ 'name' => 'remote', 'subscription_url' => 'https://example.invalid/VERY_SECRET_URL_TOKEN?key=fake' })
    refute_includes JSON.generate(source), 'VERY_SECRET'
    refute_includes JSON.generate(@db[:sources].all), 'VERY_SECRET'
    source = add_source
    refresh(source)
    refute_includes JSON.generate(@db[:nodes].all), 'VERY_SECRET_NODE_PASSWORD'
    refute_includes JSON.generate(@control.nodes({})), 'password'
    refute @control.nodes({})[:items].first.key?(:server)
  end

  def test_source_without_key_fails_closed
    manager = MPK::Services::SourceManager.new(db: @db, crypto: MPK::Services::Crypto.new(nil))
    assert_raises(MPK::Services::Failure) { manager.save({ 'name' => 'remote', 'subscription_url' => 'https://example.invalid/secret' }) }
    assert_equal 0, @db[:sources].count
  end

  def test_multiplier_examples_and_unknown
    { 'pro-澳门-20x' => 20.0, 'pro-瑞士-5x' => 5.0, 'pro-家庭宽带-日本KDDI-2x' => 2.0,
      'pro-家庭宽带-美国Wave-10X' => 10.0, '[Lv3·1.8x] 日本01' => 1.8,
      '[Lv2·2.0x] 香港02' => 2.0, '[Lv4·3.0x] 香港1|IPLC专线|AI加速' => 3.0 }.each do |name, value|
      assert_equal value, MPK::Services::NodePolicy.multiplier(name)
    end
    assert_nil MPK::Services::NodePolicy.multiplier('香港01')
    assert_nil MPK::Services::NodePolicy.multiplier('server20xname')
  end

  def test_fingerprint_ignores_name_and_hash_order_but_distinguishes_entities
    original = proxy
    policy = MPK::Services::NodePolicy
    assert_equal policy.fingerprint(original), policy.fingerprint(original.to_a.reverse.to_h.merge('name' => '新名称'))
    refute_equal policy.fingerprint(original), policy.fingerprint(original.merge('port' => 9000))
    refute_equal policy.fingerprint(original), policy.fingerprint(original.merge('password' => 'new-fake'))
  end

  def test_refresh_upsert_rename_unavailable_history_and_safe_failure
    source = add_source(proxies: [proxy, proxy('日本01', 8002)])
    refresh(source)
    first = @db[:nodes].order(:id).first
    profile = add_profile([source])
    @control.select_nodes('profile_id' => profile[:id], 'node_ids' => [first[:id]], 'selection' => 'include')
    @control.sources.save({ 'content' => YAML.dump('proxies' => [proxy('香港 renamed')]) }, id: source[:id])
    refresh(source)
    assert_equal 2, @db[:nodes].count
    renamed = @db[:nodes][id: first[:id]]
    assert_equal '香港 renamed', renamed[:original_name]
    assert_equal first[:first_seen_at], renamed[:first_seen_at]
    assert_equal 1, @db[:nodes].where(available: false).count
    assert_equal 'include', @db[:node_selections].first[:selection]
    @control.sources.save({ 'content' => 'broken VERY_SECRET_NODE_PASSWORD' }, id: source[:id])
    error = assert_raises(MPK::Services::Failure) { refresh(source) }
    refute_includes error.message, 'VERY_SECRET'
    assert_equal 1, @db[:nodes].where(available: true).count
  end

  def test_delete_source_cascades_inventory_and_selections
    source = add_source
    refresh(source)
    profile = add_profile([source])
    @control.select_nodes('profile_id' => profile[:id], 'node_ids' => [@db[:nodes].first[:id]], 'selection' => 'exclude')
    @control.sources.delete(source[:id])
    assert_equal 0, @db[:nodes].count
    assert_equal 0, @db[:node_selections].count
    assert_equal 0, @db[:profile_sources].count
    assert_equal 1, @db[:profiles].count
  end

  def test_selection_precedence_and_unknown_policy
    source = { enabled: true, max_multiplier: 2.0, unknown_multiplier_action: 'allow' }
    node = { available: true, multiplier: 3.0 }
    policy = MPK::Services::NodePolicy
    refute policy.selected?(source, node, 'auto')
    assert policy.selected?(source, node, 'include')
    refute policy.selected?(source, node, 'exclude')
    assert policy.selected?(source, node.merge(multiplier: nil), 'auto')
    refute policy.selected?(source.merge(unknown_multiplier_action: 'remove'), node.merge(multiplier: nil), 'auto')
    refute policy.selected?(source.merge(enabled: false), node.merge(multiplier: 1.0), 'auto')
    assert policy.selected?(source.merge(enabled: false), node, 'include')
    refute policy.selected?(source, node.merge(available: false), 'include')
  end

  def test_multi_source_merge_filters_before_provider_and_preserves_fingerprint
    ssone = add_source(name: 'SSONE-like', proxies: [proxy('pro-香港-01'), proxy('pro-澳门-20x', 8002)], name_prefix: 'S | ', max_multiplier: 1.0)
    tnt = add_source(name: 'TNT-like', proxies: [proxy('[Lv3·1.8x] 日本01', 9001), proxy('[Lv2·2.0x] 香港02', 9002), proxy('[Lv4·3.0x] 香港1|IPLC专线|AI加速', 9003)], name_prefix: 'T | ', max_multiplier: 2.0)
    [ssone, tnt].each { |s| refresh(s) }
    profile = add_profile([ssone, tnt])
    document, stats = @control.merge(profile)
    assert_equal 5, stats[:original_node_count]
    assert_equal 3, stats[:selected_node_count]
    assert_equal %w[chrome], document['proxies'].map { |p| p['client-fingerprint'] }.uniq
    result = @control.build(profile[:id])
    assert_equal 'success', result[:status]
    row = @db[:build_records][id: result[:id]]
    output = YAML.safe_load(File.read(row[:artifact_path]))
    assert_equal 3, output['proxies'].length
    assert output['proxies'].all? { |p| p['name'].start_with?('S | ', 'T | ') }
    assert_equal 'memconservative', output['geodata-loader']
    refute result.key?(:artifact_path)
  end

  def test_duplicate_name_failure_and_prefix_update
    a = add_source(name: 'one')
    b = add_source(name: 'two')
    [a, b].each { |s| refresh(s) }
    profile = add_profile([a, b])
    assert_raises(MPK::Services::Failure) { @control.merge(profile) }
    @control.sources.save({ 'name_prefix' => 'B | ' }, id: b[:id])
    assert_equal 'B | 香港01', @db[:nodes][source_id: b[:id]][:display_name]
    assert_equal 2, @control.merge(profile).first['proxies'].length
  end

  def test_profile_scoped_selection_and_invalid_batch_is_atomic
    a = add_source
    b = add_source(name: 'other', proxies: [proxy('US', 9001)])
    [a, b].each { |s| refresh(s) }
    profile = add_profile([a])
    ids = @db[:nodes].order(:id).select_map(:id)
    assert_raises(MPK::Services::Failure) { @control.select_nodes('profile_id' => profile[:id], 'node_ids' => ids, 'selection' => 'exclude') }
    assert_equal 0, @db[:node_selections].count
    @control.select_nodes('profile_id' => profile[:id], 'node_ids' => [ids.first], 'selection' => 'exclude')
    other = add_profile([a])
    assert_equal 1, @control.merge(other).first['proxies'].length
    assert_raises(MPK::Services::Failure) { @control.merge(profile) }
    @control.select_nodes('profile_id' => profile[:id], 'node_ids' => [ids.first], 'selection' => 'auto')
    assert_equal 0, @db[:node_selections].count
  end

  def test_failed_build_preserves_good_artifact
    source = add_source
    refresh(source)
    profile = add_profile([source])
    result = @control.build(profile[:id])
    path = @db[:build_records][id: result[:id]][:artifact_path]
    original = File.binread(path)
    @control.select_nodes('profile_id' => profile[:id], 'node_ids' => @db[:nodes].select_map(:id), 'selection' => 'exclude')
    assert_raises(MPK::Services::Failure) { @control.build(profile[:id]) }
    assert_equal original, File.binread(path)
    assert_equal 'failed', @control.builds.first[:status]
    assert_equal 'success', @control.builds.last[:status]
  end

  def test_unknown_multiplier_remove_and_base64_refresh
    source = add_source(unknown_multiplier_action: 'remove')
    refresh(source)
    assert_raises(MPK::Services::Failure) { @control.merge(add_profile([source])) }
    content = File.read(File.expand_path('providers/fixtures/source-base64-subscription.txt', __dir__))
    @control.sources.save({ 'content' => content }, id: source[:id])
    refresh(source)
    assert_operator @db[:nodes].where(available: true).count, :>, 0
  end

  def test_unresolved_providers_and_partial_uri_lists_fail
    assert_raises(MPK::Services::Failure) { @control.sources.parse(YAML.dump('proxies' => [proxy], 'proxy-providers' => { 'x' => {} })) }
    invalid = Base64.strict_encode64("vless://00000000-0000-0000-0000-000000000000@127.0.0.1:443#fixture\nunsupported://fake\n")
    assert_raises(MPK::Services::Failure) { @control.sources.parse(invalid) }
  end

  def test_pagination_filters_and_input_validation
    source = add_source(proxies: [proxy('日本-2x'), proxy('香港-3x', 8002)])
    refresh(source)
    assert_equal 1, @control.nodes('region' => 'jp', 'max_multiplier' => '2')[:total]
    assert_equal 1, @control.nodes('q' => '日本')[:total]
    assert_equal 1, @control.nodes('per_page' => '1')[:items].length
    assert_raises(MPK::Services::Failure) { @control.nodes('per_page' => '999') }
    assert_raises(MPK::Services::Failure) { @control.sources.save({ 'unknown_multiplier_action' => 'bad' }, id: source[:id]) }
    assert_raises(MPK::Services::Failure) { @control.sources.save({ 'max_multiplier' => -1 }, id: source[:id]) }
    assert_raises(MPK::Services::Failure) { @control.sources.save({ 'unexpected' => true }, id: source[:id]) }
  end
end
