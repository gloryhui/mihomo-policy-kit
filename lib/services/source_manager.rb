# frozen_string_literal: true

require 'net/http'
require 'time'
require_relative 'crypto'
require_relative 'node_policy'
require_relative '../build_helpers'

module MPK
  module Services
    class SourceManager
      MAX_BYTES = 10 * 1024 * 1024
      SOURCE_FIELDS = %i[id name enabled input_kind name_prefix max_multiplier unknown_multiplier_action refresh_interval last_refresh_at last_status last_error_safe created_at updated_at].freeze
      NODE_FIELDS = %i[id source_id fingerprint original_name display_name protocol region multiplier available first_seen_at last_seen_at].freeze

      def initialize(db:, crypto:, fetcher: nil)
        @db, @crypto = db, crypto
        @fetcher = fetcher || method(:download)
      end

      def now
        Time.now.utc.iso8601
      end

      def source(id)
        @db[:sources][id: Integer(id)] || raise(Failure.new('not_found', 'Source not found.', 404))
      end

      def dto(row)
        row.select { |k, _| SOURCE_FIELDS.include?(k) }.merge(secret_configured: !row[:subscription_url_ciphertext].to_s.empty?,
          node_count: @db[:nodes].where(source_id: row[:id]).count,
          available_node_count: @db[:nodes].where(source_id: row[:id], available: true).count)
      end

      def list
        @db[:sources].order(:id).all.map { |row| dto(row) }
      end

      def save(params, id: nil)
        old = id ? source(id) : {}
        allowed = %w[name enabled input_kind subscription_url content name_prefix max_multiplier unknown_multiplier_action refresh_interval]
        raise Failure.new('invalid_params', 'Unknown Source field.') unless (params.keys - allowed).empty?
        attrs = { name: params.fetch('name', old[:name]).to_s.strip,
          enabled: params.fetch('enabled', old.fetch(:enabled, true)),
          input_kind: params.fetch('input_kind', old.fetch(:input_kind, 'remote')),
          name_prefix: params.fetch('name_prefix', old.fetch(:name_prefix, '')).to_s,
          max_multiplier: params.fetch('max_multiplier', old[:max_multiplier]),
          unknown_multiplier_action: params.fetch('unknown_multiplier_action', old.fetch(:unknown_multiplier_action, 'allow')),
          refresh_interval: params.fetch('refresh_interval', old.fetch(:refresh_interval, 3600)), updated_at: now }
        raise Failure.new('invalid_name', 'Name must contain 1–120 characters.') unless (1..120).cover?(attrs[:name].length)
        raise Failure.new('invalid_prefix', 'Prefix must contain at most 120 characters.') if attrs[:name_prefix].length > 120
        raise Failure.new('invalid_input', 'Input must be remote or inline.') unless %w[remote inline].include?(attrs[:input_kind])
        raise Failure.new('invalid_enabled', 'enabled must be boolean.') unless [true, false].include?(attrs[:enabled])
        raise Failure.new('invalid_filter', 'Unknown multiplier action must be allow or remove.') unless %w[allow remove].include?(attrs[:unknown_multiplier_action])
        unless attrs[:max_multiplier].nil?
          attrs[:max_multiplier] = Float(attrs[:max_multiplier])
          raise ArgumentError unless attrs[:max_multiplier].finite? && attrs[:max_multiplier].positive?
        end
        attrs[:refresh_interval] = Integer(attrs[:refresh_interval])
        raise ArgumentError unless (60..604_800).cover?(attrs[:refresh_interval])
        value = params[attrs[:input_kind] == 'remote' ? 'subscription_url' : 'content']
        if value
          raise Failure.new('input_too_large', 'Subscription input is too large.') if value.to_s.bytesize > MAX_BYTES
          validate_url(value) if attrs[:input_kind] == 'remote'
          encrypted = @crypto.encrypt(value)
          encrypted.each { |k, v| attrs["subscription_url_#{k}".to_sym] = v }
        elsif old.empty? || old[:input_kind] != attrs[:input_kind]
          raise Failure.new('missing_input', 'A subscription URL or file content is required.')
        end
        @db.transaction do
          if id
            @db[:sources].where(id: id).update(attrs)
            if old[:name_prefix] != attrs[:name_prefix]
              @db[:nodes].where(source_id: id).each do |node|
                @db[:nodes].where(id: node[:id]).update(display_name: attrs[:name_prefix] + node[:original_name])
              end
            end
          else
            id = @db[:sources].insert(attrs.merge(created_at: now))
          end
        end
        dto(source(id))
      rescue ArgumentError, TypeError
        raise Failure.new('invalid_params', 'Invalid numeric Source setting.')
      end

      def delete(id)
        source(id)
        @db[:sources].where(id: id).delete
        { deleted: true }
      end

      def refresh(id)
        row = source(id)
        encrypted = %i[ciphertext iv tag].to_h { |k| [k, row["subscription_url_#{k}".to_sym]] }
        value = @crypto.decrypt(encrypted)
        content = row[:input_kind] == 'remote' ? @fetcher.call(value) : value
        proxies = parse(content)
        stamp = now
        # Parse/encrypt the entire candidate before changing availability, so
        # corrupt responses and wrong keys leave the previous inventory intact.
        candidates = proxies.map do |proxy|
          secret = @crypto.encrypt(JSON.generate(proxy))
          { source_id: id, fingerprint: NodePolicy.fingerprint(proxy),
            original_name: proxy.fetch('name'), display_name: row[:name_prefix] + proxy.fetch('name'),
            protocol: proxy.fetch('type'), server: proxy.fetch('server'), port: Integer(proxy.fetch('port')),
            region: NodePolicy.region(proxy['name']), multiplier: NodePolicy.multiplier(proxy['name']),
            available: true, last_seen_at: stamp }.merge(secret.to_h { |k, v| ["proxy_#{k}".to_sym, v] })
        end
        @db.transaction do
          @db[:nodes].where(source_id: id).update(available: false)
          candidates.each do |candidate|
            existing = @db[:nodes][source_id: id, fingerprint: candidate[:fingerprint]]
            if existing
              @db[:nodes].where(id: existing[:id]).update(candidate)
            else
              @db[:nodes].insert(candidate.merge(first_seen_at: stamp))
            end
          end
          @db[:sources].where(id: id).update(last_refresh_at: stamp, last_status: 'success', last_error_safe: nil, updated_at: stamp)
        end
        dto(source(id))
      rescue StandardError => e
        safe = e.is_a?(Failure) ? e : Failure.new('refresh_failed', 'Refresh failed; check subscription format or network connectivity.')
        @db[:sources].where(id: id).update(last_status: 'failed', last_error_safe: safe.message, updated_at: now) if row
        raise safe
      end

      def parse(content)
        raise Failure.new('invalid_subscription', 'Subscription is empty or too large.') if content.to_s.empty? || content.bytesize > MAX_BYTES
        if BuildHelpers.yaml_subscription?(content)
          document = YAML.safe_load(content, permitted_classes: [Symbol], aliases: true)
          raise Failure.new('unresolved_provider', 'Node inventory requires concrete proxies; unresolved proxy-providers are unsupported.') unless (document['proxy-providers'] || {}).empty?
          proxies = document['proxies']
        else
          decoded = BuildHelpers.decode_base64_nodes(content)
          raise Failure.new('invalid_subscription', 'Expected Mihomo YAML or a base64 URI list.') unless decoded
          lines = decoded.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
          proxies = lines.map { |line| BuildHelpers.parse_node_uri(line) }
        end
        valid = proxies.is_a?(Array) && !proxies.empty? && proxies.all? do |p|
          p.is_a?(Hash) && %w[name type server].all? { |k| p[k].is_a?(String) && !p[k].empty? } && (1..65_535).cover?(Integer(p['port']))
        end
        raise Failure.new('invalid_subscription', 'Subscription contains missing or unsupported node fields.') unless valid
        fingerprints = proxies.map { |p| NodePolicy.fingerprint(p) }
        raise Failure.new('duplicate_entity', 'Subscription contains duplicate node entities.') unless fingerprints.uniq.length == fingerprints.length
        proxies
      rescue Failure
        raise
      rescue StandardError
        raise Failure.new('invalid_subscription', 'Subscription could not be parsed; previous nodes were preserved.')
      end

      def validate_url(value)
        uri = URI.parse(value.to_s)
        raise ArgumentError unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment
        uri
      rescue ArgumentError, URI::InvalidURIError
        raise Failure.new('invalid_url', 'Subscription URL must be HTTPS without userinfo or fragment.')
      end

      def download(url, redirects = 0)
        uri = validate_url(url)
        raise Failure.new('download_failed', 'Subscription download failed.') if redirects > 3
        response = nil
        body = +''
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30, write_timeout: 15) do |http|
          http.request(Net::HTTP::Get.new(uri.request_uri)) do |res|
            response = res
            if res.is_a?(Net::HTTPSuccess)
              res.read_body do |chunk|
                body << chunk
                raise Failure.new('input_too_large', 'Subscription response is too large.') if body.bytesize > MAX_BYTES
              end
            end
          end
        end
        return download(URI.join(url, response['location']).to_s, redirects + 1) if response.is_a?(Net::HTTPRedirection)
        raise Failure.new('download_failed', 'Subscription download failed.') unless response.is_a?(Net::HTTPSuccess)
        body.force_encoding(Encoding::UTF_8)
      rescue Failure
        raise
      rescue StandardError
        raise Failure.new('download_failed', 'Subscription download failed; check URL and connectivity.')
      end
    end
  end
end
