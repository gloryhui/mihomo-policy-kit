# frozen_string_literal: true

require 'json'
require 'yaml'
require_relative '../overlay'
require_relative '../build_helpers'

module MPK
  module OutputAdapters
    class Base
      BUILTIN_TARGETS = %w[DIRECT REJECT REJECT-DROP PASS].freeze
      COMMON_RULE_TYPES = %w[DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD IP-CIDR IP-CIDR6 GEOIP MATCH].freeze

      def id
        raise NotImplementedError
      end

      def extension
        raise NotImplementedError
      end

      def render(_policy)
        raise NotImplementedError
      end

      def write(content, output_path)
        BuildHelpers.write_text_atomic(content, output_path, extension: extension)
      end

      def validate(_content)
        # Subclasses with a concrete wire format override this.  Keeping the
        # hook on the small fixed contract lets OutputPipeline validate all
        # selected results before it begins promotion.
      end

      # Core-level validation on a staged candidate file (e.g. `mihomo -t`).
      # Runs during OutputPipeline.write_all *before* any candidate is promoted,
      # so a failing core check cannot leave a partial update.  Default no-op.
      def validate_core(_candidate_path)
        # no-op for adapters without an external core to test
      end

      private

      def mapping!(policy)
        raise Error, "#{id} adapter input must be a mapping" unless policy.is_a?(Hash)

        policy
      end

      def proxy_list(policy)
        proxies = Array(policy['proxies'])
        raise Error, "#{id} adapter cannot render an empty proxy list" if proxies.empty?

        proxies.each { |proxy| require_proxy_identity!(proxy) }
        proxies
      end

      def require_proxy_identity!(proxy)
        raise Error, "#{id} adapter proxy entry must be a mapping" unless proxy.is_a?(Hash)
        raise Error, "#{id} adapter proxy is missing name" if proxy['name'].to_s.empty?
        raise Error, "#{id} adapter proxy #{proxy['name']} is missing type" if proxy['type'].to_s.empty?
      end

      def require_no_proxy_providers!(policy)
        return unless policy['proxy-providers'].is_a?(Hash) && !policy['proxy-providers'].empty?

        raise Error, "#{id} adapter does not support proxy-providers; export concrete proxies instead"
      end

      def group_names(policy)
        Array(policy['proxy-groups']).filter_map { |group| group['name'] if group.is_a?(Hash) }
      end

      def all_policy_targets(policy)
        proxy_list(policy).map { |proxy| proxy['name'] } + group_names(policy) + BUILTIN_TARGETS
      end

      def validate_group_references!(policy, allow_provider_use: false)
        validate_unique_policy_names!(policy)
        targets = all_policy_targets(policy)
        Array(policy['proxy-groups']).each do |group|
          raise Error, "#{id} adapter proxy group must be a mapping" unless group.is_a?(Hash)
          name = group['name'].to_s
          raise Error, "#{id} adapter proxy group is missing name" if name.empty?
          Array(group['proxies']).each do |target|
            next if targets.include?(target)
            raise Error, "#{id} adapter group #{name} references missing policy"
          end
          if !allow_provider_use && (group.key?('use') || group.key?('include-all'))
            raise Error, "#{id} adapter does not support proxy-provider group membership"
          end
        end
      end

      def validate_unique_policy_names!(policy)
        names = proxy_list(policy).map { |proxy| proxy['name'] } + group_names(policy)
        duplicate = names.group_by(&:itself).find { |_name, entries| entries.length > 1 }&.first
        raise Error, "#{id} adapter has duplicate proxy or group name: #{duplicate}" if duplicate

        reserved = names.find { |name| BUILTIN_TARGETS.include?(name) }
        raise Error, "#{id} adapter proxy or group name conflicts with built-in target: #{reserved}" if reserved
      end

      def rule_parts(rule)
        Array(rule.to_s.split(',')).map(&:strip)
      end

      def target_for_rule(parts)
        type = parts.first.to_s.upcase
        return parts[1] if type == 'MATCH'
        return nil if parts.length < 3

        parts[2]
      end

      def validate_rules!(policy, supported: COMMON_RULE_TYPES)
        targets = all_policy_targets(policy)
        rules = Array(policy['rules'])
        raise Error, "#{id} adapter cannot render an empty rule list" if rules.empty?
        rules.each do |rule|
          parts = rule_parts(rule)
          type = parts.first.to_s.upcase
          raise Error, "#{id} adapter does not support rule type: #{type}" unless supported.include?(type)
          target = target_for_rule(parts)
          raise Error, "#{id} adapter rule has no policy target" if target.to_s.empty?
          raise Error, "#{id} adapter rule references missing policy" unless targets.include?(target)
        end
      end

      def conf_value(value)
        raw = value.to_s
        return raw unless raw.match?(/[\s,="]/)

        '"' + raw.gsub('"', '\\"') + '"'
      end

      def optional_bool(proxy, source, dest)
        return nil unless proxy.key?(source)

        "#{dest}=#{proxy[source] ? 'true' : 'false'}"
      end

      def supported_proxy!(proxy, supported)
        type = proxy['type'].to_s.downcase
        return type if supported.include?(type)

        # Deliberately omit all sensitive fields from compatibility diagnostics.
        raise Error, "#{id} adapter does not support proxy type: #{type}"
      end

      def require_fields!(proxy, *fields)
        missing = fields.reject { |field| !proxy[field].to_s.empty? }
        return if missing.empty?

        raise Error, "#{id} adapter proxy #{proxy['name']} is missing required fields: #{missing.join(', ')}"
      end

      # A protocol field that is not converted is a silent downgrade.  Keep
      # adapter scopes deliberately small and make such fields a capability
      # error rather than emitting a plausible-but-broken subscription.
      def reject_unmapped_fields!(proxy, allowed)
        unsupported = proxy.keys.map(&:to_s).reject { |key| allowed.include?(key) }
        return if unsupported.empty?

        raise Error, "#{id} adapter does not support proxy fields: #{unsupported.sort.join(', ')}"
      end

      # A proxy-group field that is not converted is a silent downgrade.  Keep
      # group scopes explicit per type and make unknown fields a capability
      # error rather than emitting a plausible-but-broken group.
      def reject_unmapped_group_fields!(group, allowed)
        unsupported = group.keys.map(&:to_s).reject { |key| allowed.include?(key) }
        return if unsupported.empty?

        raise Error, "#{id} adapter does not support proxy group fields: #{unsupported.sort.join(', ')}"
      end

      # Render the supported key=value group parameters that are actually
      # present, in a stable order.  Only keys the caller whitelists are read.
      def group_param_parts(group, keys)
        keys.filter_map do |key|
          next unless group.key?(key)

          "#{key}=#{conf_value(group[key])}"
        end
      end
    end
  end
end
