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
        'dns_profile' => 'upstream'
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
        { 'name' => 'US-01', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'test' }
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
      refute document.key?('global-client-fingerprint')
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

  def test_unknown_target_fails_early
    Dir.mktmpdir do |dir|
      rules = File.join(dir, 'custom.list')
      File.write(rules, "DOMAIN-SUFFIX,example.com,mars\n")

      overlay = MPK::Overlay.new(config: base_config(rules), group_map: group_map)
      document = base_document

      assert_raises(MPK::Error) { overlay.apply!(document, root_dir: dir) }
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

  def test_china_compat_dns_keeps_unrelated_fields
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
            'geosite:cn' => ['https://dns.alidns.com/dns-query']
          }
        }
      )

      overlay.apply!(document, root_dir: dir)

      assert_equal 'fake-ip', document.dig('dns', 'enhanced-mode')
      assert_equal ['223.5.5.5', '119.29.29.29'], document.dig('dns', 'default-nameserver')
      refute document.dig('dns', 'nameserver-policy').key?('geosite:geolocation-!cn')
      assert document.dig('dns', 'nameserver-policy').key?('geosite:cn')
    end
  end
end
