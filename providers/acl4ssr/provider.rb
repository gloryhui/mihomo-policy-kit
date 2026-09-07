# frozen_string_literal: true

require 'yaml'

path = ARGV.fetch(0)
doc = YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: true) || {}
raise 'provider input must be a mapping' unless doc.is_a?(Hash)
proxies = Array(doc['proxies'])
names = proxies.filter_map { |p| p.is_a?(Hash) ? p['name'] : nil }
regions = {
  'ACL4SSR Hong Kong' => '(?i)香港|hong[ -]?kong|hk',
  'ACL4SSR Japan' => '(?i)日本|东京|大阪|japan|jp',
  'ACL4SSR Singapore' => '(?i)新加坡|狮城|singapore|sg',
  'ACL4SSR United States' => '(?i)美国|美|united states|usa|us'
}
groups = regions.map { |name, regex| { 'name' => name, 'type' => 'select', 'filter' => regex, 'proxies' => ['DIRECT'] + names } }
groups += [
  { 'name' => 'ACL4SSR Global', 'type' => 'select', 'proxies' => ['ACL4SSR United States', 'ACL4SSR Hong Kong', 'ACL4SSR Japan', 'ACL4SSR Singapore'] },
  { 'name' => 'ACL4SSR AI', 'type' => 'select', 'proxies' => ['ACL4SSR Global'] },
  { 'name' => 'ACL4SSR Final', 'type' => 'select', 'proxies' => ['ACL4SSR Global', 'DIRECT'] }
]
doc['proxy-groups'] = groups
doc['rule-providers'] ||= {}
doc['rule-providers']['acl4ssr-lan'] = { 'type' => 'http', 'behavior' => 'classical', 'url' => 'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Providers/Ruleset/LocalAreaNetwork.list', 'path' => './ruleset/acl4ssr-lan.list', 'interval' => 86400 }
provider_base = 'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Providers/Ruleset'
doc['rule-providers']['acl4ssr-ads'] = { 'type' => 'http', 'behavior' => 'classical', 'url' => "#{provider_base}/AdBlock.list", 'path' => './ruleset/acl4ssr-ads.list', 'interval' => 86400 }
%w[Google Microsoft Telegram Netflix Youtube Global].each do |service|
  key = "acl4ssr-#{service.downcase}"
  doc['rule-providers'][key] = { 'type' => 'http', 'behavior' => 'classical', 'url' => "#{provider_base}/#{service}.list", 'path' => "./ruleset/#{key}.list", 'interval' => 86400 }
end
doc['rules'] = [
  'RULE-SET,acl4ssr-lan,DIRECT', 'RULE-SET,acl4ssr-ads,REJECT',
  'RULE-SET,acl4ssr-google,ACL4SSR Global', 'RULE-SET,acl4ssr-microsoft,ACL4SSR Global',
  'RULE-SET,acl4ssr-telegram,ACL4SSR Global', 'RULE-SET,acl4ssr-netflix,ACL4SSR Global',
  'RULE-SET,acl4ssr-youtube,ACL4SSR Global', 'RULE-SET,acl4ssr-global,ACL4SSR Global',
  'MATCH,ACL4SSR Final'
]
File.write(path, YAML.dump(doc))
