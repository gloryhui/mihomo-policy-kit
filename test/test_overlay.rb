# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/overlay'

class OverlayTest < Minitest::Test
  def base_config(rule_file)
    {
      'custom_rules' => {
        'files' => [rule_file],
        'allow_missing' => false
      },
      'patches' => {
        'remove_global_client_fingerprint' => true,
        'dns_profile' => 'upstream',
        'geodata_loader' => 'memconservative'
      },
      'validation' => {
        'min_proxy_count' => 1,
        'require_proxy_groups' => true,
        'require_rules' => true,
        'require_targets' => %w[ai global direct]
      }
    }
  end

  def group_map
    {
      'ai' => '🤖 AI 服务',
      'global' => '🌍 全球节点',
      'direct' => 'DIRECT',
      'reject' => 'REJECT'
    }
  end

  def base_document
    {
      'global-client-fingerprint' => 'chrome',
      'proxies' => [
        { 'name' => 'US-01', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm',
          'password' => 'test',
          'client-fingerprint' => 'chrome' }
      ],
      'proxy-groups' => [
        { 'name' => '🤖 AI 服务', 'type' => 'select', 'proxies' => ['🌍 全球节点'] },
        { 'name' => '🌍 全球节点', 'type' => 'select', 'proxies' => ['US-01'] }
      ],
      'rules' => ['MATCH,🌍 全球节点']
    }
  end

  def test_custom_rule_is_mapped_and_prepended
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "DOMAIN-SUFFIX,experientiallabs.ai,ai\n")

      overlay = MPK::Overlay.new(config: base_config(rules), group_map: group_map)
      document = base_document
      overlay.apply!(document, root_dir: dir)

      assert_equal 'DOMAIN-SUFFIX,experientiallabs.ai,🤖 AI 服务', document['rules'].first
      assert_equal 'MATCH,🌍 全球节点', document['rules'].last
    end
  end

  def test_ip_rule_preserves_no_resolve
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "IP-CIDR,192.168.0.0/16,direct,no-resolve\n")

      overlay = MPK::Overlay.new(config: base_config(rules), group_map: group_map)
      document = base_document
      overlay.apply!(document, root_dir: dir)

      assert_equal 'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve', document['rules'].first
    end
  end

  def test_custom_rule_precedence_over_provider_rules
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "DOMAIN-SUFFIX,example.com,us\n")

      config = base_config(rules)
      overlay = MPK::Overlay.new(config: config, group_map: group_map.merge('us' => '🇺🇸 美国节点'))
      document = base_document.merge('rules' => ['DOMAIN-SUFFIX,example.com,🤖 AI 服务', 'MATCH,🌍 全球节点'])
      overlay.apply!(document, root_dir: dir)

      assert_equal 'DOMAIN-SUFFIX,example.com,🇺🇸 美国节点', document['rules'].first
      # Provider 原有规则仍在，且用户规则在最前
      assert_equal 'DOMAIN-SUFFIX,example.com,🤖 AI 服务', document['rules'][1]
    end
  end

  def test_global_fingerprint_removed_and_node_fingerprint_kept
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "DOMAIN-SUFFIX,experientiallabs.ai,ai\n")

      overlay = MPK::Overlay.new(config: base_config(rules), group_map: group_map)
      document = base_document
      overlay.apply!(document, root_dir: dir)

      refute document.key?('global-client-fingerprint')
      assert_equal 'chrome', document['proxies'].first['client-fingerprint']
    end
  end

  def test_node_fingerprint_kept_even_without_custom_rules
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "")

      overlay = MPK::Overlay.new(config: base_config(rules), group_map: group_map)
      document = base_document
      overlay.apply!(document, root_dir: dir)

      refute document.key?('global-client-fingerprint')
      assert_equal 'chrome', document['proxies'].first['client-fingerprint']
    end
  end

  def test_geodata_loader_defaults_to_memconservative
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "")

      overlay = MPK::Overlay.new(config: base_config(rules), group_map: group_map)
      document = base_document
      overlay.apply!(document, root_dir: dir)

      assert_equal 'memconservative', document['geodata-loader']
    end
  end

  def test_geodata_loader_upstream_removes_loader
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "")

      config = base_config(rules)
      config['patches']['geodata_loader'] = 'upstream'
      overlay = MPK::Overlay.new(config: config, group_map: group_map)
      document = base_document.merge('geodata-loader' => 'standard')
      overlay.apply!(document, root_dir: dir)

      refute document.key?('geodata-loader')
    end
  end

  def test_unknown_geodata_loader_fails
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "")

      config = base_config(rules)
      config['patches']['geodata_loader'] = 'quantum'
      overlay = MPK::Overlay.new(config: config, group_map: group_map)

      assert_raises(MPK::Error) { overlay.apply!(base_document, root_dir: dir) }
    end
  end

  def test_unknown_target_fails_early
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "DOMAIN-SUFFIX,example.com,mars\n")

      overlay = MPK::Overlay.new(config: base_config(rules), group_map: group_map)
      document = base_document

      assert_raises(MPK::Error) { overlay.apply!(document, root_dir: dir) }
    end
  end

  def test_missing_required_group_fails
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "DOMAIN-SUFFIX,example.com,ai\n")

      overlay = MPK::Overlay.new(config: base_config(rules), group_map: group_map)
      # 文档中没有 "🤖 AI 服务" 组
      document = base_document.merge(
        'proxy-groups' => [
          { 'name' => '🌍 全球节点', 'type' => 'select', 'proxies' => ['US-01'] }
        ]
      )

      error = assert_raises(MPK::Error) { overlay.validate!(document, source_proxy_count: 1) }
      assert_match(/required target missing/, error.message)
    end
  end

  def test_proxy_loss_guard
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "")

      overlay = MPK::Overlay.new(config: base_config(rules), group_map: group_map)
      document = base_document.merge('proxies' => [])

      error = assert_raises(MPK::Error) do
        overlay.validate!(document, source_proxy_count: 12)
      end

      assert_match(/proxy|usable/i, error.message)
    end
  end

  def test_upstream_dns_profile_leaves_dns_untouched
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "")

      config = base_config(rules)
      config['patches']['dns_profile'] = 'upstream'
      overlay = MPK::Overlay.new(config: config, group_map: group_map)
      original_dns = {
        'enable' => true,
        'enhanced-mode' => 'fake-ip',
        'nameserver' => ['https://1.1.1.1/dns-query'],
        'fallback' => ['https://8.8.8.8/dns-query'],
        'nameserver-policy' => { 'geosite:cn' => ['https://dns.alidns.com/dns-query'] }
      }
      document = base_document.merge('dns' => original_dns)

      overlay.apply!(document, root_dir: dir)

      assert_equal original_dns, document['dns']
    end
  end

  def test_china_compat_dns_sets_all_expected_fields
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "")

      config = base_config(rules)
      config['patches']['dns_profile'] = 'china_compat'
      overlay = MPK::Overlay.new(config: config, group_map: group_map)
      document = base_document.merge('dns' => { 'enhanced-mode' => 'fake-ip' })

      overlay.apply!(document, root_dir: dir)

      dns = document['dns']
      assert_equal true, dns['enable']
      assert_equal false, dns['respect-rules']
      assert_equal ['223.5.5.5', '119.29.29.29'], dns['default-nameserver']
      assert_equal ['https://223.5.5.5/dns-query', 'https://120.53.53.53/dns-query'], dns['nameserver']
      assert_equal ['https://223.5.5.5/dns-query', 'https://120.53.53.53/dns-query'], dns['proxy-server-nameserver']
      assert_equal ['https://223.5.5.5/dns-query', 'https://120.53.53.53/dns-query'], dns['direct-nameserver']
      assert_equal false, dns['direct-nameserver-follow-policy']
      assert_equal ['https://223.5.5.5/dns-query', 'https://120.53.53.53/dns-query'], dns['fallback']
    end
  end

  def test_china_compat_dns_removes_foreign_bootstrap_policies_and_keeps_others
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "")

      config = base_config(rules)
      config['patches']['dns_profile'] = 'china_compat'
      overlay = MPK::Overlay.new(config: config, group_map: group_map)
      document = base_document.merge(
        'dns' => {
          'enhanced-mode' => 'fake-ip',
          'nameserver-policy' => {
            'geosite:geolocation-!cn' => ['https://dns.google/dns-query'],
            '+.jsdelivr.net' => ['https://dns.google/dns-query'],
            '+.github.com' => ['https://dns.google/dns-query'],
            '+.githubusercontent.com' => ['https://dns.google/dns-query'],
            '+.githubassets.com' => ['https://dns.google/dns-query'],
            '+.fastly.net' => ['https://dns.google/dns-query'],
            'geosite:cn' => ['https://dns.alidns.com/dns-query'],
            '+.foo.example' => ['https://dns.alidns.com/dns-query']
          }
        }
      )

      overlay.apply!(document, root_dir: dir)

      policy = document.dig('dns', 'nameserver-policy')
      %w[
        geosite:geolocation-!cn
        +.jsdelivr.net
        +.github.com
        +.githubusercontent.com
        +.githubassets.com
        +.fastly.net
      ].each { |key| refute policy.key?(key), "expected #{key} removed" }

      assert policy.key?('geosite:cn')
      assert policy.key?('+.foo.example')
      assert_equal 'fake-ip', document.dig('dns', 'enhanced-mode')
    end
  end

  def test_unknown_dns_profile_fails
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "")

      config = base_config(rules)
      config['patches']['dns_profile'] = 'mars'
      overlay = MPK::Overlay.new(config: config, group_map: group_map)

      assert_raises(MPK::Error) { overlay.apply!(base_document, root_dir: dir) }
    end
  end
end
