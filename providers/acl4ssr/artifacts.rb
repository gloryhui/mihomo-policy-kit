# frozen_string_literal: true

# ACL4SSR publishes these as YAML `payload:` rule-provider artifacts.  Keep the
# allowlist in the provider directory so generated configurations cannot silently
# drift to guessed / removed upstream .list paths.
module MPK
  module ACL4SSR
    RAW_BASE = 'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash'.freeze

    ARTIFACTS = {
      'acl4ssr-lan' => ['Providers/LocalAreaNetwork.yaml', 'classical'],
      'acl4ssr-ads' => ['Providers/BanAD.yaml', 'classical'],
      'acl4ssr-china-domain' => ['Providers/ChinaDomain.yaml', 'classical'],
      'acl4ssr-china-ip' => ['Providers/ChinaIp.yaml', 'ipcidr'],
      'acl4ssr-ai' => ['Providers/Ruleset/AI.yaml', 'classical'],
      'acl4ssr-google' => ['Providers/Ruleset/Google.yaml', 'classical'],
      'acl4ssr-microsoft' => ['Providers/Ruleset/Microsoft.yaml', 'classical'],
      'acl4ssr-telegram' => ['Providers/Ruleset/Telegram.yaml', 'classical'],
      'acl4ssr-netflix' => ['Providers/Ruleset/Netflix.yaml', 'classical'],
      'acl4ssr-youtube' => ['Providers/Ruleset/YouTube.yaml', 'classical'],
      'acl4ssr-proxy' => ['Providers/ProxyGFWlist.yaml', 'classical']
    }.freeze

    module_function

    def rule_provider(key)
      relative_path, behavior = ARTIFACTS.fetch(key)
      {
        'type' => 'http',
        'behavior' => behavior,
        'url' => "#{RAW_BASE}/#{relative_path}",
        'path' => "./ruleset/#{key}.yaml",
        'interval' => 86_400
      }
    end
  end
end
