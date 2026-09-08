# frozen_string_literal: true

require 'yaml'
require_relative 'artifacts'

path = ARGV.fetch(0)
doc = YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: true) || {}
raise 'provider input must be a mapping' unless doc.is_a?(Hash)
proxies = Array(doc['proxies'])
names = proxies.filter_map { |p| p.is_a?(Hash) ? p['name'] : nil }
provider_names = doc['proxy-providers'].is_a?(Hash) ? doc['proxy-providers'].keys.map(&:to_s) : []
regions = {
  'ACL4SSR Hong Kong' => '(?i)香港|hong[ -]?kong|hk',
  'ACL4SSR Japan' => '(?i)日本|东京|大阪|japan|jp',
  'ACL4SSR Singapore' => '(?i)新加坡|狮城|singapore|sg',
  'ACL4SSR United States' => '(?i)美国|美|united states|usa|us'
}
groups = regions.map do |name, regex|
  # A static `proxies` list is not filtered by Mihomo's `filter`; filter those
  # names here.  For proxy-providers, `use` + `filter` is Mihomo's provider
  # selection mechanism and keeps runtime-fetched node lists usable.
  group = { 'name' => name, 'type' => 'select', 'proxies' => ['DIRECT'] + names.grep(Regexp.new(regex)) }
  unless provider_names.empty?
    group['use'] = provider_names
    group['filter'] = regex
  end
  group
end
global = {
  'name' => 'ACL4SSR Global',
  'type' => 'select',
  'proxies' => ['ACL4SSR United States', 'ACL4SSR Hong Kong', 'ACL4SSR Japan', 'ACL4SSR Singapore'] + names
}
global['use'] = provider_names unless provider_names.empty?
groups += [
  global,
  { 'name' => 'ACL4SSR AI', 'type' => 'select', 'proxies' => ['ACL4SSR Global'] },
  { 'name' => 'ACL4SSR Final', 'type' => 'select', 'proxies' => ['ACL4SSR Global', 'DIRECT'] }
]
doc['proxy-groups'] = groups
doc['rule-providers'] ||= {}
MPK::ACL4SSR::ARTIFACTS.each_key do |key|
  doc['rule-providers'][key] = MPK::ACL4SSR.rule_provider(key)
end
doc['rules'] = [
  'RULE-SET,acl4ssr-lan,DIRECT', 'RULE-SET,acl4ssr-ads,REJECT',
  'RULE-SET,acl4ssr-china-domain,DIRECT', 'RULE-SET,acl4ssr-china-ip,DIRECT',
  'RULE-SET,acl4ssr-ai,ACL4SSR AI',
  'RULE-SET,acl4ssr-google,ACL4SSR Global', 'RULE-SET,acl4ssr-microsoft,ACL4SSR Global',
  'RULE-SET,acl4ssr-telegram,ACL4SSR Global', 'RULE-SET,acl4ssr-netflix,ACL4SSR Global',
  'RULE-SET,acl4ssr-youtube,ACL4SSR Global', 'RULE-SET,acl4ssr-proxy,ACL4SSR Global',
  'MATCH,ACL4SSR Final'
]
File.write(path, YAML.dump(doc))
