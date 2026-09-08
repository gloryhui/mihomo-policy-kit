# frozen_string_literal: true

require 'ipaddr'

module MPK
  module OutputAdapters
    class SingBox < Base
      SUPPORTED_PROXIES = %w[ss vmess trojan].freeze

      def id = 'sing-box'
      def extension = '.json'

      def render(policy)
        mapping!(policy)
        require_no_proxy_providers!(policy)
        proxies = proxy_list(policy)
        proxies.each { |proxy| supported_proxy!(proxy, SUPPORTED_PROXIES) }
        validate_group_references!(policy)
        validate_rules!(policy, supported: COMMON_RULE_TYPES - ['GEOIP'])

        document = {
          'outbounds' => [
            { 'type' => 'direct', 'tag' => 'direct' }
          ] + proxies.map { |proxy| render_proxy(proxy) } + Array(policy['proxy-groups']).map { |group| render_group(group) },
          'route' => render_route(policy)
        }
        JSON.pretty_generate(document) + "\n"
      end

      def validate(content)
        document = JSON.parse(content)
        tags = Array(document['outbounds']).filter_map { |outbound| outbound['tag'] if outbound.is_a?(Hash) }
        raise Error, 'sing-box adapter output has no outbounds' if tags.empty?
        # The legacy `block` outbound was removed in sing-box 1.13.0; never emit it.
        if Array(document['outbounds']).any? { |outbound| outbound.is_a?(Hash) && outbound['type'] == 'block' }
          raise Error, 'sing-box adapter must not emit the removed block outbound'
        end
        Array(document.dig('route', 'rules')).each do |rule|
          # A reject action has no outbound; only route actions reference one.
          next if rule['action'] == 'reject'

          target = rule['outbound']
          raise Error, 'sing-box adapter route references missing outbound' unless tags.include?(target)
        end
        final = document.dig('route', 'final')
        raise Error, 'sing-box adapter final references missing outbound' unless tags.include?(final)

      rescue JSON::ParserError => e
        raise Error, "sing-box adapter produced invalid JSON: #{e.message}"
      end

      def write(content, output_path)
        validate(content)
        super
      end

      private

      def render_proxy(proxy)
        require_ip_server!(proxy)
        case proxy['type'].to_s.downcase
        when 'ss'
          reject_unmapped_fields!(proxy, %w[name type server port cipher password udp])
          require_fields!(proxy, 'server', 'port', 'cipher', 'password')
          document = { 'type' => 'shadowsocks', 'tag' => proxy['name'], 'server' => proxy['server'], 'server_port' => proxy['port'], 'method' => proxy['cipher'], 'password' => proxy['password'] }
          document['network'] = 'tcp' if proxy.key?('udp') && !proxy['udp']
          document
        when 'vmess'
          reject_unmapped_fields!(proxy, %w[name type server port uuid cipher alterId network tls sni servername udp skip-cert-verify ws-opts])
          require_fields!(proxy, 'server', 'port', 'uuid')
          transport = proxy['network'].to_s
          if !transport.empty? && transport != 'tcp'
            raise Error, 'sing-box adapter does not support VMess transport other than tcp'
          end
          raise Error, 'sing-box adapter does not support VMess websocket options' if proxy.key?('ws-opts')
          document = { 'type' => 'vmess', 'tag' => proxy['name'], 'server' => proxy['server'], 'server_port' => proxy['port'], 'uuid' => proxy['uuid'], 'security' => proxy.fetch('cipher', 'auto'), 'alter_id' => proxy.fetch('alterId', 0) }
          document['network'] = 'tcp' if proxy.key?('udp') && !proxy['udp']
          if proxy['tls']
            tls = { 'enabled' => true }
            server_name = proxy['servername'] || proxy['sni']
            tls['server_name'] = server_name unless server_name.to_s.empty?
            tls['insecure'] = proxy['skip-cert-verify'] ? true : false if proxy.key?('skip-cert-verify')
            document['tls'] = tls
          end
          document
        when 'trojan'
          reject_unmapped_fields!(proxy, %w[name type server port password network tls sni servername udp skip-cert-verify])
          require_fields!(proxy, 'server', 'port', 'password')
          transport = proxy['network'].to_s
          raise Error, 'sing-box adapter only supports Trojan tcp transport' unless transport.empty? || transport == 'tcp'
          raise Error, 'sing-box adapter Trojan cannot disable TLS' if proxy.key?('tls') && !proxy['tls']
          document = { 'type' => 'trojan', 'tag' => proxy['name'], 'server' => proxy['server'], 'server_port' => proxy['port'], 'password' => proxy['password'] }
          document['network'] = 'tcp' if proxy.key?('udp') && !proxy['udp']
          tls = { 'enabled' => true }
          server_name = proxy['servername'] || proxy['sni']
          tls['server_name'] = server_name unless server_name.to_s.empty?
          tls['insecure'] = proxy['skip-cert-verify'] ? true : false if proxy.key?('skip-cert-verify')
          document['tls'] = tls
          document
        end
      end

      def render_group(group)
        type = group['type'].to_s
        raise Error, "sing-box adapter does not support proxy group type: #{type}" unless type == 'select'
        { 'type' => 'selector', 'tag' => group['name'], 'outbounds' => Array(group['proxies']).map { |name| outbound_target(name) }, 'default' => outbound_target(Array(group['proxies']).first) }
      end

      def render_route(policy)
        rules = []
        final = nil
        Array(policy['rules']).each do |rule|
          parts = rule_parts(rule)
          type = parts.first.to_s.upcase
          if type == 'MATCH'
            final = outbound_target(parts[1])
            next
          end
          raise Error, 'sing-box adapter does not support rule options' if parts.length > 3
          key = {
            'DOMAIN' => 'domain',
            'DOMAIN-SUFFIX' => 'domain_suffix',
            'DOMAIN-KEYWORD' => 'domain_keyword',
            'IP-CIDR' => 'ip_cidr',
            'IP-CIDR6' => 'ip_cidr'
          }.fetch(type)
          target = parts[2]
          rendered = { key => [parts[1]] }
          case target.to_s.upcase
          when 'REJECT'
            # Current sing-box expresses rejection as a route action, not an
            # outbound.  The legacy `block` outbound was removed in 1.13.0.
            rendered['action'] = 'reject'
          when 'REJECT-DROP'
            raise Error, 'sing-box adapter does not support REJECT-DROP action'
          else
            rendered['action'] = 'route'
            rendered['outbound'] = outbound_target(target)
          end
          rules << rendered
        end
        raise Error, 'sing-box adapter requires a MATCH final rule' if final.nil?
        { 'rules' => rules, 'final' => final }
      end

      def outbound_target(name)
        case name.to_s
        when 'DIRECT' then 'direct'
        when 'REJECT', 'REJECT-DROP'
          # A selector member or route.final cannot express rejection as an
          # outbound in current sing-box; hard-fail rather than fabricate a
          # removed `block` outbound.
          raise Error, 'sing-box adapter cannot express REJECT as an outbound target in current sing-box'
        else name.to_s
        end
      end

      # V0.4 keeps DNS out of scope, but sing-box 1.14 requires a resolver for
      # outbounds whose server address is a hostname.  Accept only IP-literal
      # servers and hard-fail on hostnames rather than emitting an incomplete
      # config.  The message never includes password/UUID/token.
      def require_ip_server!(proxy)
        server = proxy['server'].to_s
        return if ip_literal?(server)

        raise Error, "sing-box adapter requires an IP-literal server (V0.4 does not convert DNS/domain_resolver); proxy #{proxy['name']} uses a hostname"
      end

      def ip_literal?(value)
        IPAddr.new(value)
        true
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
