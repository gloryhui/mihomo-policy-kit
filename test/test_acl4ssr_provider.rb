# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'open3'
require 'rbconfig'
require_relative '../providers/acl4ssr/artifacts'

class ACL4SSRProviderTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  PROVIDER = File.join(ROOT, 'providers/acl4ssr/provider.rb')
  FIXTURES = File.join(ROOT, 'test/providers/fixtures')

  def run_provider(fixture)
    Dir.mktmpdir('mpk-acl4ssr-') do |dir|
      target = File.join(dir, 'source.yaml')
      File.binwrite(target, File.binread(File.join(FIXTURES, fixture)))
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, PROVIDER, target)
      assert status.success?, "provider failed: #{stdout} #{stderr}"
      return YAML.safe_load(File.read(target), aliases: true)
    end
  end

  def group(doc, name)
    Array(doc['proxy-groups']).find { |item| item['name'] == name }
  end

  def test_rule_provider_allowlist_uses_existing_official_yaml_artifacts
    expected_paths = {
      'acl4ssr-lan' => 'Providers/LocalAreaNetwork.yaml',
      'acl4ssr-ads' => 'Providers/BanAD.yaml',
      'acl4ssr-china-domain' => 'Providers/ChinaDomain.yaml',
      'acl4ssr-china-ip' => 'Providers/ChinaIp.yaml',
      'acl4ssr-ai' => 'Providers/Ruleset/AI.yaml',
      'acl4ssr-google' => 'Providers/Ruleset/Google.yaml',
      'acl4ssr-microsoft' => 'Providers/Ruleset/Microsoft.yaml',
      'acl4ssr-telegram' => 'Providers/Ruleset/Telegram.yaml',
      'acl4ssr-netflix' => 'Providers/Ruleset/Netflix.yaml',
      'acl4ssr-youtube' => 'Providers/Ruleset/YouTube.yaml',
      'acl4ssr-proxy' => 'Providers/ProxyGFWlist.yaml'
    }
    assert_equal expected_paths, MPK::ACL4SSR::ARTIFACTS.transform_values(&:first)

    doc = run_provider('source-fixture.yaml')
    expected_paths.each_key do |key|
      provider = doc.fetch('rule-providers').fetch(key)
      assert_equal "#{MPK::ACL4SSR::RAW_BASE}/#{expected_paths.fetch(key)}", provider['url']
      assert_match(/\.yaml\z/, provider['url'])
      refute_match(/\.list\z/, provider['url'])
    end
    assert_equal 'ipcidr', doc.dig('rule-providers', 'acl4ssr-china-ip', 'behavior')
    assert_equal 'classical', doc.dig('rule-providers', 'acl4ssr-ai', 'behavior')
  end

  def test_ai_china_and_final_rules_have_required_targets_and_order
    doc = run_provider('source-fixture.yaml')
    rules = doc.fetch('rules')
    assert_includes rules, 'RULE-SET,acl4ssr-ai,ACL4SSR AI'
    assert_includes rules, 'RULE-SET,acl4ssr-china-domain,DIRECT'
    assert_includes rules, 'RULE-SET,acl4ssr-china-ip,DIRECT'
    assert_includes rules, 'RULE-SET,acl4ssr-proxy,ACL4SSR Global'
    assert_equal 'MATCH,ACL4SSR Final', rules.last
    assert_operator rules.index('RULE-SET,acl4ssr-china-domain,DIRECT'), :<, rules.index('RULE-SET,acl4ssr-ai,ACL4SSR AI')
    assert_operator rules.index('RULE-SET,acl4ssr-ai,ACL4SSR AI'), :<, rules.index('MATCH,ACL4SSR Final')
  end

  def test_static_region_groups_only_contain_matching_nodes
    doc = run_provider('source-regions.yaml')
    expected = {
      'ACL4SSR Hong Kong' => ['Hong Kong-HK'],
      'ACL4SSR Japan' => ['Tokyo-JP'],
      'ACL4SSR Singapore' => ['Singapore-SG'],
      'ACL4SSR United States' => ['United States-US']
    }
    expected.each do |name, nodes|
      proxies = group(doc, name).fetch('proxies')
      assert_equal ['DIRECT'] + nodes, proxies
      refute_includes proxies, 'Germany-Other'
    end
    assert_includes group(doc, 'ACL4SSR Global').fetch('proxies'), 'Germany-Other'
  end

  def test_proxy_provider_only_input_is_usable_by_global_and_region_groups
    doc = run_provider('source-proxy-providers.yaml')
    provider_name = 'fixture-provider'
    global = group(doc, 'ACL4SSR Global')
    assert_equal [provider_name], global['use']
    %w[ACL4SSR\ Hong\ Kong ACL4SSR\ Japan ACL4SSR\ Singapore ACL4SSR\ United\ States].each do |name|
      region = group(doc, name)
      assert_equal [provider_name], region['use']
      refute_nil region['filter']
    end
  end
end
