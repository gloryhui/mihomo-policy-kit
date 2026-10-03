# frozen_string_literal: true

require 'digest'
require 'json'

module MPK
  module Services
    module NodePolicy
      module_function

      def multiplier(name)
        match = name.to_s.match(/(?<![\w.])(\d+(?:\.\d+)?)\s*[xX](?![a-zA-Z0-9])/)
        match && Float(match[1])
      end

      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |k| [k, canonical(value[k])] }
        when Array then value.map { |v| canonical(v) }
        else value
        end
      end

      def fingerprint(proxy)
        Digest::SHA256.hexdigest(JSON.generate(canonical(proxy.reject { |k, _| k == 'name' })))
      end

      def region(name)
        { 'hk' => /香港|Hong\s*Kong|🇭🇰/i, 'jp' => /日本|Japan|🇯🇵/i,
          'us' => /美国|United\s*States|🇺🇸/i, 'sg' => /新加坡|Singapore|🇸🇬/i,
          'tw' => /台湾|Taiwan|🇹🇼/i, 'mo' => /澳门|Macau|🇲🇴/i,
          'ch' => /瑞士|Switzerland|🇨🇭/i }.find { |_, pattern| name.to_s.match?(pattern) }&.first || 'unknown'
      end

      def selected?(source, node, selection)
        return false if selection == 'exclude'
        # Forced inclusion bypasses cost/enabled filters, but stale nodes cannot
        # supply a currently usable endpoint.
        return false unless node[:available]
        return true if selection == 'include'
        return false unless source[:enabled]
        cost = node[:multiplier]
        return source[:unknown_multiplier_action] == 'allow' if cost.nil?
        source[:max_multiplier].nil? || cost <= source[:max_multiplier]
      end
    end
  end
end
