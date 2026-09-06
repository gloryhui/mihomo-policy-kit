# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'tempfile'

module MPK
  class Error < StandardError; end

  module YAMLUtil
    module_function

    def load_file(path)
      content = File.read(path, encoding: 'UTF-8')
      YAML.safe_load(content, permitted_classes: [Symbol], aliases: true) || {}
    rescue Errno::ENOENT
      raise Error, "YAML file not found: #{path}"
    rescue Psych::Exception => e
      raise Error, "invalid YAML #{path}: #{e.message}"
    end

    def atomic_write(path, object)
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory)

      Tempfile.create(['mpk-', '.yaml'], directory) do |tmp|
        tmp.write(YAML.dump(object))
        tmp.flush
        tmp.fsync
        File.rename(tmp.path, path)
      end
    end
  end

  class Overlay
    SIMPLE_POLICY_INDEX_2 = %w[
      DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD DOMAIN-REGEX
      GEOSITE GEOIP IP-ASN
      IP-CIDR IP-CIDR6 SRC-IP-CIDR SRC-IP-CIDR6
      SRC-PORT DST-PORT IN-PORT
      PROCESS-NAME PROCESS-PATH PROCESS-NAME-REGEX PROCESS-PATH-REGEX
      RULE-SET NETWORK DSCP-REWRITE
    ].freeze

    SIMPLE_POLICY_INDEX_1 = %w[MATCH].freeze

    attr_reader :config, :group_map

    def initialize(config:, group_map:)
      @config = config
      @group_map = group_map
    end

    def apply!(document, root_dir:)
      ensure_hash!(document)
      apply_common_patches!(document)
      apply_custom_rules!(document, root_dir: root_dir)
      document
    end

    def validate!(document, source_proxy_count: nil)
      ensure_hash!(document)

      proxies = Array(document['proxies'])
      proxy_providers = document['proxy-providers']
      groups = Array(document['proxy-groups'])
      rules = Array(document['rules'])

      min_proxy_count = dig(config, 'validation', 'min_proxy_count', default: 1).to_i
      provider_count = proxy_providers.is_a?(Hash) ? proxy_providers.length : 0

      if proxies.length < min_proxy_count && provider_count.zero?
        raise Error, "final config has no usable proxy source: proxies=#{proxies.length}, proxy-providers=#{provider_count}"
      end

      if source_proxy_count && source_proxy_count.positive? && proxies.empty?
        raise Error, "proxy-loss guard triggered: source proxies=#{source_proxy_count}, final proxies=0"
      end

      if truthy?(dig(config, 'validation', 'require_proxy_groups', default: true)) && groups.empty?
        raise Error, 'final config has no proxy-groups'
      end

      if truthy?(dig(config, 'validation', 'require_rules', default: true)) && rules.empty?
        raise Error, 'final config has no rules'
      end

      group_names = groups.filter_map { |group| group.is_a?(Hash) ? group['name'] : nil }
      builtin_targets = %w[DIRECT REJECT REJECT-DROP PASS]

      Array(dig(config, 'validation', 'require_targets', default: [])).each do |logical_target|
        actual_target = resolve_target(logical_target)
        next if builtin_targets.include?(actual_target)
        next if group_names.include?(actual_target)

        raise Error, "required target missing: #{logical_target} -> #{actual_target}"
      end

      {
        proxies: proxies.length,
        proxy_providers: provider_count,
        proxy_groups: groups.length,
        rules: rules.length
      }
    end

    def resolve_target(logical_target)
      key = logical_target.to_s.strip
      mapped = group_map[key]
      return mapped.to_s unless mapped.nil? || mapped.to_s.empty?

      # 允许显式使用 Mihomo 内建动作，但普通策略组必须走映射，避免绑定上游命名。
      return key if %w[DIRECT REJECT REJECT-DROP PASS].include?(key)

      raise Error, "unknown logical target: #{key}"
    end

    private

    def apply_common_patches!(document)
      if truthy?(dig(config, 'patches', 'remove_global_client_fingerprint', default: true))
        document.delete('global-client-fingerprint')
      end

      geodata_loader = dig(config, 'patches', 'geodata_loader', default: 'memconservative').to_s
      if geodata_loader.empty? || geodata_loader == 'upstream'
        document.delete('geodata-loader')
      elsif %w[memconservative standard].include?(geodata_loader)
        document['geodata-loader'] = geodata_loader
      else
        raise Error, "unknown geodata-loader: #{geodata_loader}"
      end

      case dig(config, 'patches', 'dns_profile', default: 'upstream').to_s
      when '', 'upstream'
        nil
      when 'china_compat'
        apply_china_compat_dns!(document)
      else
        raise Error, "unknown dns profile: #{dig(config, 'patches', 'dns_profile')}"
      end
    end

    def apply_china_compat_dns!(document)
      dns = document['dns']
      dns = {} unless dns.is_a?(Hash)
      document['dns'] = dns

      domestic_doh = [
        'https://223.5.5.5/dns-query',
        'https://120.53.53.53/dns-query'
      ]

      dns['enable'] = true
      dns['respect-rules'] = false
      dns['default-nameserver'] = ['223.5.5.5', '119.29.29.29']
      dns['nameserver'] = domestic_doh.dup
      dns['proxy-server-nameserver'] = domestic_doh.dup
      dns['direct-nameserver'] = domestic_doh.dup
      dns['direct-nameserver-follow-policy'] = false
      dns['fallback'] = domestic_doh.dup

      policy = dns['nameserver-policy']
      if policy.is_a?(Hash)
        %w[
          geosite:geolocation-!cn
          +.jsdelivr.net
          +.github.com
          +.githubusercontent.com
          +.githubassets.com
          +.fastly.net
        ].each { |key| policy.delete(key) }
      end
    end

    def apply_custom_rules!(document, root_dir:)
      files = Array(dig(config, 'custom_rules', 'files', default: []))
      allow_missing = truthy?(dig(config, 'custom_rules', 'allow_missing', default: true))
      custom_rules = []

      files.each do |configured_path|
        path = absolute_path(configured_path, root_dir)
        unless File.file?(path)
          if allow_missing
            warn "[overlay] custom rule file missing; skipped: #{path}"
            next
          end
          raise Error, "custom rule file missing: #{path}"
        end

        File.foreach(path, chomp: true).with_index(1) do |line, line_number|
          stripped = line.strip
          next if stripped.empty? || stripped.start_with?('#')

          custom_rules << compile_rule(stripped, source: "#{path}:#{line_number}")
        end
      end

      return if custom_rules.empty?

      existing = Array(document['rules'])
      document['rules'] = deduplicate_preserving_order(custom_rules + existing)
    end

    def compile_rule(rule, source:)
      tokens = rule.split(',').map(&:strip)
      type = tokens.first.to_s.upcase

      policy_index = if SIMPLE_POLICY_INDEX_2.include?(type)
                       2
                     elsif SIMPLE_POLICY_INDEX_1.include?(type)
                       1
                     else
                       raise Error, "unsupported custom rule type #{type.inspect} at #{source}"
                     end

      if tokens.length <= policy_index || tokens[policy_index].to_s.empty?
        raise Error, "missing target in custom rule at #{source}: #{rule}"
      end

      tokens[policy_index] = resolve_target(tokens[policy_index])
      tokens.join(',')
    end

    def deduplicate_preserving_order(values)
      seen = {}
      values.each_with_object([]) do |value, result|
        next if seen[value]

        seen[value] = true
        result << value
      end
    end

    def absolute_path(path, root_dir)
      expanded = File.expand_path(path.to_s, root_dir)
      expanded
    end

    def ensure_hash!(document)
      raise Error, 'root YAML document must be a mapping' unless document.is_a?(Hash)
    end

    def truthy?(value)
      value == true || value.to_s.downcase == 'true' || value.to_s == '1'
    end

    def dig(hash, *keys, default: nil)
      current = hash
      keys.each do |key|
        return default unless current.is_a?(Hash) && current.key?(key)

        current = current[key]
      end
      current.nil? ? default : current
    end
  end
end
