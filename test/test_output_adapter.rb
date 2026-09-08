# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'yaml'
require 'fileutils'
require_relative '../lib/output_adapter'

class OutputAdapterTest < Minitest::Test
  def supported_policy
    {
      'proxies' => [
        { 'name' => 'Fake-SS', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'fake-password-ss' },
        { 'name' => 'Fake-VMess', 'type' => 'vmess', 'server' => '127.0.0.2', 'port' => 443, 'uuid' => '00000000-0000-0000-0000-000000000000', 'cipher' => 'auto', 'alterId' => 0 }
      ],
      'proxy-groups' => [
        { 'name' => 'US', 'type' => 'select', 'proxies' => ['Fake-SS', 'DIRECT'] },
        { 'name' => 'Global', 'type' => 'select', 'proxies' => ['US', 'Fake-VMess', 'DIRECT'] },
        { 'name' => 'Final', 'type' => 'select', 'proxies' => ['Global', 'DIRECT'] }
      ],
      'rules' => ['DOMAIN-SUFFIX,example.invalid,Global', 'IP-CIDR,192.0.2.0/24,DIRECT', 'MATCH,Final']
    }
  end

  def adapter(id)
    MPK::OutputRegistry.new.fetch(id)
  end

  def test_registry_defaults_and_unknown_id
    registry = MPK::OutputRegistry.new
    assert_equal %w[mihomo stash loon surge sing-box], registry.selected('outputs' => %w[mihomo stash loon surge sing-box])
    assert_equal ['mihomo'], registry.selected({})
    error = assert_raises(MPK::Error) { registry.fetch('unknown-client') }
    assert_equal 'unknown output adapter: unknown-client', error.message
  end

  def test_all_adapters_render_and_validate_supported_fixture
    rendered = {}
    %w[mihomo stash loon surge sing-box].each { |id| rendered[id] = adapter(id).render(supported_policy) }

    stash = YAML.safe_load(rendered.fetch('stash'), aliases: true)
    assert_equal 'rule', stash['mode']
    assert_equal %w[Fake-SS Fake-VMess], stash['proxies'].map { |proxy| proxy['name'] }
    assert_equal 'MATCH,Final', stash['rules'].last

    %w[loon surge].each do |id|
      text = rendered.fetch(id)
      %w[[General] [Proxy] [Proxy\ Group] [Rule]].each { |section| assert_includes text, section }
      assert_includes text, 'FINAL,Final'
      assert_includes text, 'Fake-SS'
      assert_includes text, 'Fake-VMess'
    end

    sing_box = JSON.parse(rendered.fetch('sing-box'))
    tags = sing_box.fetch('outbounds').map { |outbound| outbound['tag'] }
    assert_includes tags, 'Global'
    assert_equal 'Final', sing_box.dig('route', 'final')
    assert_equal 'route', sing_box.dig('route', 'rules', 0, 'action')
  end

  def test_unsupported_protocol_diagnostics_do_not_leak_secret_fields
    policy = supported_policy
    policy['proxies'][0] = { 'name' => 'Unsupported', 'type' => 'mieru', 'server' => 'example.invalid', 'port' => 443, 'password' => 'VERY_SECRET_ADAPTER_PASSWORD' }
    %w[stash loon surge sing-box].each do |id|
      error = assert_raises(MPK::Error) { adapter(id).render(policy) }
      assert_includes error.message, 'does not support proxy type: mieru'
      refute_includes error.message, 'VERY_SECRET_ADAPTER_PASSWORD'
    end
  end

  def test_vless_is_explicitly_rejected_where_not_implemented
    policy = supported_policy
    policy['proxies'][0]['type'] = 'vless'
    %w[loon surge sing-box].each do |id|
      error = assert_raises(MPK::Error) { adapter(id).render(policy) }
      assert_includes error.message, 'does not support proxy type: vless'
    end
  end

  def test_missing_rule_target_fails_instead_of_becoming_direct
    policy = supported_policy
    policy['rules'][0] = 'DOMAIN-SUFFIX,example.invalid,Missing-Policy'
    %w[stash loon surge sing-box].each do |id|
      error = assert_raises(MPK::Error) { adapter(id).render(policy) }
      assert_includes error.message, 'references missing policy'
      refute_includes error.message, 'DIRECT'
    end
  end

  def test_non_stash_adapters_reject_rule_sets_and_proxy_providers
    policy = supported_policy.merge('rules' => ['RULE-SET,remote,Global', 'MATCH,Final'])
    %w[loon surge sing-box].each do |id|
      error = assert_raises(MPK::Error) { adapter(id).render(policy) }
      assert_includes error.message, 'does not support rule type: RULE-SET'
    end

    provider_policy = supported_policy.merge('proxy-providers' => { 'remote' => { 'type' => 'http' } })
    %w[loon surge sing-box].each do |id|
      error = assert_raises(MPK::Error) { adapter(id).render(provider_policy) }
      assert_includes error.message, 'does not support proxy-providers'
    end
  end

  def test_sing_box_rejects_untranslated_vmess_websocket_transport
    policy = supported_policy
    policy['proxies'][1]['network'] = 'ws'
    policy['proxies'][1]['ws-opts'] = { 'path' => '/socket' }
    error = assert_raises(MPK::Error) { adapter('sing-box').render(policy) }
    assert_includes error.message, 'does not support VMess transport other than tcp'
  end

  def test_sing_box_rejects_deprecated_geoip_and_clash_only_rule_options
    geoip_policy = supported_policy
    geoip_policy['rules'][0] = 'GEOIP,CN,Global'
    geoip_error = assert_raises(MPK::Error) { adapter('sing-box').render(geoip_policy) }
    assert_includes geoip_error.message, 'does not support rule type: GEOIP'

    option_policy = supported_policy
    option_policy['rules'][1] = 'IP-CIDR,192.0.2.0/24,DIRECT,no-resolve'
    option_error = assert_raises(MPK::Error) { adapter('sing-box').render(option_policy) }
    assert_includes option_error.message, 'does not support rule options'

    reject_drop_policy = supported_policy
    reject_drop_policy['rules'][0] = 'DOMAIN-SUFFIX,example.invalid,REJECT-DROP'
    reject_drop_error = assert_raises(MPK::Error) { adapter('sing-box').render(reject_drop_policy) }
    assert_includes reject_drop_error.message, 'does not support REJECT-DROP action'

    group_policy = supported_policy
    group_policy['proxy-groups'][0]['type'] = 'url-test'
    group_error = assert_raises(MPK::Error) { adapter('sing-box').render(group_policy) }
    assert_includes group_error.message, 'does not support proxy group type: url-test'
  end

  def test_loon_and_surge_preserve_vmess_tls_and_trojan_websocket_details
    policy = supported_policy
    policy['proxies'][1].merge!('network' => 'ws', 'tls' => true, 'sni' => 'vmess.example.invalid',
                                'ws-opts' => { 'path' => '/vmess', 'headers' => { 'Host' => 'host.example.invalid' } })
    policy['proxies'] << { 'name' => 'Fake-Trojan', 'type' => 'trojan', 'server' => '127.0.0.3', 'port' => 443,
                            'password' => 'fake-password-trojan', 'network' => 'ws', 'sni' => 'trojan.example.invalid',
                            'ws-opts' => { 'path' => '/trojan', 'headers' => { 'Host' => 'host.example.invalid' } } }
    policy['proxy-groups'][1]['proxies'] << 'Fake-Trojan'

    loon = adapter('loon').render(policy)
    assert_includes loon, 'over-tls=true'
    assert_includes loon, 'sni=vmess.example.invalid'
    assert_includes loon, 'transport=ws,path=/trojan,host=host.example.invalid,sni=trojan.example.invalid'

    surge = adapter('surge').render(policy)
    assert_includes surge, 'tls=true'
    assert_includes surge, 'sni=vmess.example.invalid'
    assert_includes surge, 'ws=true, ws-path=/trojan, ws-headers=Host:host.example.invalid, sni=trojan.example.invalid'
  end

  def test_render_failure_does_not_overwrite_an_existing_output
    Dir.mktmpdir('mpk-output-') do |dir|
      output = File.join(dir, 'mihomo.yaml')
      File.write(output, 'GOOD_EXISTING_OUTPUT')
      policy = supported_policy
      policy['proxies'][0]['type'] = 'vless'
      config = { 'outputs' => %w[mihomo loon], 'output' => { 'mihomo' => output, 'loon' => File.join(dir, 'loon.conf') } }

      assert_raises(MPK::Error) { MPK::OutputPipeline.render_all(policy, config) }
      assert_equal 'GOOD_EXISTING_OUTPUT', File.read(output)
      refute File.exist?(File.join(dir, 'loon.conf'))
    end
  end

  def test_non_mihomo_write_is_atomic_and_parseable
    Dir.mktmpdir('mpk-output-') do |dir|
      output = File.join(dir, 'sing-box.json')
      content = adapter('sing-box').render(supported_policy)
      adapter('sing-box').write(content, output)
      assert_equal JSON.parse(content), JSON.parse(File.read(output))
    end
  end

  # Sol Review #3 (P0): Surge VMess must emit the AEAD decision explicitly.
  def test_surge_vmess_aead_flag_reflects_alter_id
    surge = adapter('surge').render(supported_policy)
    assert_includes surge, 'vmess-aead=true'

    legacy = supported_policy
    legacy['proxies'][1]['alterId'] = 1
    legacy_surge = adapter('surge').render(legacy)
    assert_includes legacy_surge, 'vmess-aead=false'
  end

  # Sol Review #3 (P1): url-test/fallback group params must be mapped to the
  # target client's real semantics, not copied verbatim from Mihomo keys.
  def test_surge_maps_supported_group_params_and_rejects_unsupported
    # Surge url-test supports interval/tolerance; fallback supports interval.
    policy = supported_policy
    policy['proxy-groups'] = [
      { 'name' => 'Auto', 'type' => 'url-test', 'proxies' => ['Fake-SS', 'Fake-VMess'], 'interval' => 300, 'tolerance' => 100 },
      { 'name' => 'Backup', 'type' => 'fallback', 'proxies' => ['Fake-SS', 'Fake-VMess'], 'interval' => 600 },
      { 'name' => 'Final', 'type' => 'select', 'proxies' => ['Auto', 'Backup', 'DIRECT'] }
    ]
    policy['rules'] = ['DOMAIN-SUFFIX,example.invalid,Auto', 'MATCH,Final']

    surge = adapter('surge').render(policy)
    assert_includes surge, 'Auto = url-test, Fake-SS, Fake-VMess, interval=300, tolerance=100'
    assert_includes surge, 'Backup = fallback, Fake-SS, Fake-VMess, interval=600'

    # group-level url has no effect in current Surge -> hard fail
    url_policy = supported_policy
    url_policy['proxy-groups'][0] = { 'name' => 'US', 'type' => 'url-test', 'proxies' => ['Fake-SS', 'DIRECT'], 'url' => 'http://www.gstatic.com/generate_204' }
    url_error = assert_raises(MPK::Error) { adapter('surge').render(url_policy) }
    assert_includes url_error.message, 'does not support proxy group fields'

    # lazy has no proven Surge equivalent -> hard fail
    lazy_policy = supported_policy
    lazy_policy['proxy-groups'][0] = { 'name' => 'US', 'type' => 'url-test', 'proxies' => ['Fake-SS', 'DIRECT'], 'lazy' => true }
    lazy_error = assert_raises(MPK::Error) { adapter('surge').render(lazy_policy) }
    assert_includes lazy_error.message, 'does not support proxy group fields'
  end

  def test_loon_maps_supported_group_params_and_rejects_lazy
    # Loon url-test supports url/interval/tolerance; fallback supports url/interval.
    policy = supported_policy
    policy['proxy-groups'] = [
      { 'name' => 'Auto', 'type' => 'url-test', 'proxies' => ['Fake-SS', 'Fake-VMess'],
        'url' => 'http://www.gstatic.com/generate_204', 'interval' => 300, 'tolerance' => 100 },
      { 'name' => 'Backup', 'type' => 'fallback', 'proxies' => ['Fake-SS', 'Fake-VMess'],
        'url' => 'http://www.gstatic.com/generate_204', 'interval' => 600 },
      { 'name' => 'Final', 'type' => 'select', 'proxies' => ['Auto', 'Backup', 'DIRECT'] }
    ]
    policy['rules'] = ['DOMAIN-SUFFIX,example.invalid,Auto', 'MATCH,Final']

    loon = adapter('loon').render(policy)
    assert_includes loon, 'Auto = url-test,Fake-SS,Fake-VMess,url=http://www.gstatic.com/generate_204,interval=300,tolerance=100'
    assert_includes loon, 'Backup = fallback,Fake-SS,Fake-VMess,url=http://www.gstatic.com/generate_204,interval=600'

    # lazy has no Loon equivalent -> hard fail
    lazy_policy = supported_policy
    lazy_policy['proxy-groups'][0] = { 'name' => 'US', 'type' => 'url-test', 'proxies' => ['Fake-SS', 'DIRECT'], 'lazy' => true }
    lazy_error = assert_raises(MPK::Error) { adapter('loon').render(lazy_policy) }
    assert_includes lazy_error.message, 'does not support proxy group fields'
  end

  # Sol Review #3 (P1): unknown group fields must hard-fail, not silently drop.
  def test_surge_and_loon_reject_unknown_group_fields
    policy = supported_policy
    policy['proxy-groups'][0]['unknown-param'] = 'x'
    %w[surge loon].each do |id|
      error = assert_raises(MPK::Error) { adapter(id).render(policy) }
      assert_includes error.message, 'does not support proxy group fields'
    end
  end

  # Sol Review #3 (P1): a failing Mihomo core check must prevent ANY promotion,
  # including an earlier stash artifact, because core validation runs before
  # promotion in write_all.
  def test_mihomo_core_failure_prevents_any_promotion
    Dir.mktmpdir('mpk-output-') do |dir|
      stash_output = File.join(dir, 'stash.yaml')
      mihomo_output = File.join(dir, 'mihomo.yaml')
      File.write(stash_output, 'GOOD_OLD_STASH')
      config = { 'outputs' => %w[stash mihomo], 'output' => { 'stash' => stash_output, 'mihomo' => mihomo_output } }

      rendered = MPK::OutputPipeline.render_all(supported_policy, config)

      original = BuildHelpers.method(:validate_mihomo_core)
      BuildHelpers.singleton_class.send(:define_method, :validate_mihomo_core) do |_path|
        raise MPK::Error, 'mihomo config test failed (simulated)'
      end

      begin
        assert_raises(MPK::Error) { MPK::OutputPipeline.write_all(rendered) }
      ensure
        BuildHelpers.singleton_class.send(:define_method, :validate_mihomo_core, original)
      end

      # No promotion happened: old stash untouched, mihomo not created.
      assert_equal 'GOOD_OLD_STASH', File.read(stash_output)
      refute File.exist?(mihomo_output)
    end
  end
end
