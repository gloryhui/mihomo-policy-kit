# frozen_string_literal: true

module MPK
  module OutputAdapters
    # Stash accepts Clash-format YAML.  Emit only its policy-bearing sections;
    # DNS/TUN and other host-specific Mihomo settings intentionally stay out of
    # this V0.4 artifact rather than being guessed.
    class Stash < Base
      SUPPORTED_PROXIES = %w[ss vmess trojan vless].freeze
      SUPPORTED_RULES = (COMMON_RULE_TYPES + ['RULE-SET']).freeze

      def id = 'stash'
      def extension = '.yaml'

      def render(policy)
        mapping!(policy)
        proxies = proxy_list(policy)
        proxies.each { |proxy| supported_proxy!(proxy, SUPPORTED_PROXIES) }
        validate_group_references!(policy, allow_provider_use: true)
        validate_rules!(policy, supported: SUPPORTED_RULES)
        validate_rule_provider_references!(policy)

        rendered = {
          'mode' => 'rule',
          'proxies' => proxies,
          'proxy-groups' => Array(policy['proxy-groups']),
          'rules' => Array(policy['rules'])
        }
        rendered['proxy-providers'] = policy['proxy-providers'] if policy['proxy-providers'].is_a?(Hash) && !policy['proxy-providers'].empty?
        rendered['rule-providers'] = policy['rule-providers'] if policy['rule-providers'].is_a?(Hash) && !policy['rule-providers'].empty?
        YAML.dump(rendered)
      end

      def validate(content)
        document = YAML.safe_load(content, permitted_classes: [Symbol], aliases: true)
        raise Error, 'stash adapter produced invalid YAML' unless document.is_a?(Hash)
        raise Error, 'stash adapter output has no proxies' if Array(document['proxies']).empty?
        raise Error, 'stash adapter output has no proxy-groups' if Array(document['proxy-groups']).empty?
        raise Error, 'stash adapter output has no rules' if Array(document['rules']).empty?

      rescue Psych::Exception => e
        raise Error, "stash adapter produced invalid YAML: #{e.message}"
      end

      def write(content, output_path)
        validate(content)
        super
      end

      private

      def validate_rule_provider_references!(policy)
        providers = policy['rule-providers'].is_a?(Hash) ? policy['rule-providers'].keys : []
        Array(policy['rules']).each do |rule|
          parts = rule_parts(rule)
          next unless parts.first.to_s.upcase == 'RULE-SET'
          next if providers.include?(parts[1])

          raise Error, 'stash adapter RULE-SET references missing rule-provider'
        end
      end
    end
  end
end
