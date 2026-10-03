# frozen_string_literal: true

require_relative 'database'
require_relative 'source_manager'
require_relative 'build_pipeline'
require_relative '../publisher/publisher'

module MPK
  module Services
    class ControlPlane
      attr_reader :db, :sources, :data_root

      def initialize(db:, data_root:, crypto:, publisher: nil, fetcher: nil, config: nil)
        @db, @data_root = db, File.expand_path(data_root)
        FileUtils.mkdir_p(@data_root)
        @sources = SourceManager.new(db: db, crypto: crypto, fetcher: fetcher)
        @crypto = crypto
        @config = config || BuildHelpers.load_config(File.join(BuildHelpers::ROOT_DIR, 'config/config.example.yaml'))
        @publisher = publisher || MPK::Publisher::Publisher.new(root: @data_root)
        # Publisher token records contain bearer bytes. Nginx may traverse the
        # root/builds through its group, but must not read private token state.
        unless Gem.win_platform?
          token_dir = File.join(@publisher.root, 'token-state') if @publisher.respond_to?(:root)
          if token_dir
            FileUtils.mkdir_p(token_dir, mode: 0o700)
            File.chmod(0o700, token_dir)
          end
        end
        @mutex = Mutex.new
      end

      def locked
        @mutex.synchronize do
          File.open(File.join(@data_root, 'control-plane.lock'), 'a') do |file|
            file.flock(File::LOCK_EX)
            begin
              yield
            ensure
              file.flock(File::LOCK_UN)
            end
          end
        end
      end

      def profile(id)
        db[:profiles][id: Integer(id)] || raise(Failure.new('not_found', 'Profile not found.', 404))
      end

      def profile_dto(row)
        row.merge(source_ids: db[:profile_sources].where(profile_id: row[:id]).select_map(:source_id))
      end

      def profiles
        db[:profiles].order(:id).all.map { |row| profile_dto(row) }
      end

      def save_profile(params, id: nil)
        old = id ? profile(id) : {}
        raise Failure.new('invalid_params', 'Unknown Profile field.') unless (params.keys - %w[name enabled provider dns_profile source_ids]).empty?
        attrs = { name: params.fetch('name', old[:name]).to_s.strip,
          provider: params.fetch('provider', old.fetch(:provider, 'smart-config-kit')),
          dns_profile: params.fetch('dns_profile', old.fetch(:dns_profile, 'upstream')),
          enabled: params.fetch('enabled', old.fetch(:enabled, true)), updated_at: sources.now }
        raise Failure.new('invalid_profile', 'Profile name, Provider, DNS or enabled value is invalid.') unless
          (1..120).cover?(attrs[:name].length) && %w[smart-config-kit acl4ssr].include?(attrs[:provider]) &&
          %w[upstream china_compat].include?(attrs[:dns_profile]) && [true, false].include?(attrs[:enabled])
        ids = params.fetch('source_ids', id ? profile_dto(old)[:source_ids] : [])
        raise Failure.new('invalid_sources', 'source_ids must be an array.') unless ids.is_a?(Array)
        ids = ids.map { |value| Integer(value) }.uniq
        ids.each { |source_id| sources.source(source_id) }
        db.transaction do
          if id
            db[:profiles].where(id: id).update(attrs)
            db[:profile_sources].where(profile_id: id).delete
          else
            id = db[:profiles].insert(attrs.merge(created_at: sources.now))
          end
          ids.each { |source_id| db[:profile_sources].insert(profile_id: id, source_id: source_id) }
          # Choices for detached sources cannot silently apply if reattached.
          node_ids = db[:nodes].where(source_id: ids).select(:id)
          db[:node_selections].where(profile_id: id).exclude(node_id: node_ids).delete
        end
        profile_dto(profile(id))
      rescue ArgumentError, TypeError
        raise Failure.new('invalid_sources', 'Source IDs must be integers.')
      end

      def delete_profile(id)
        profile(id)
        db[:profiles].where(id: id).delete
        { deleted: true }
      end

      def nodes(params)
        dataset = db[:nodes]
        if params['profile_id'] && !params['profile_id'].empty?
          selected_profile = profile(Integer(params['profile_id']))
          source_ids = profile_dto(selected_profile)[:source_ids]
          dataset = dataset.where(source_id: source_ids)
          selections = db[:node_selections].where(profile_id: selected_profile[:id]).all.to_h { |row| [row[:node_id], row[:selection]] }
        else
          selections = {}
        end
        dataset = dataset.where(source_id: Integer(params['source_id'])) if params['source_id'] && !params['source_id'].empty?
        dataset = dataset.where(region: params['region']) if params['region'] && !params['region'].empty?
        if params['available'] && !params['available'].empty?
          raise ArgumentError unless %w[true false].include?(params['available'])
          dataset = dataset.where(available: params['available'] == 'true')
        end
        if params['q'] && !params['q'].empty?
          # Escape SQL LIKE metacharacters; Sequel escapes literal values.
          query = params['q'].to_s.gsub(/[\\%_]/) { |c| '\\' + c }
          dataset = dataset.where(Sequel.|(Sequel.like(:original_name, "%#{query}%"), Sequel.like(:display_name, "%#{query}%")))
        end
        if params['max_multiplier'] && !params['max_multiplier'].empty?
          ceiling = Float(params['max_multiplier'])
          raise ArgumentError unless ceiling.finite? && ceiling.positive?
          dataset = dataset.where { multiplier <= ceiling }
        end
        dataset = dataset.where(multiplier: nil) if params['unknown_multiplier'] == 'true'
        page = Integer(params.fetch('page', 1))
        per_page = Integer(params.fetch('per_page', 50))
        raise ArgumentError unless page.positive? && (1..200).cover?(per_page)
        total = dataset.count
        source_map = db[:sources].all.to_h { |s| [s[:id], s] }
        items = dataset.order(:id).limit(per_page, (page - 1) * per_page).all.map do |row|
          source = source_map.fetch(row[:source_id])
          selection = selections.fetch(row[:id], 'auto')
          row.select { |k, _| SourceManager::NODE_FIELDS.include?(k) }.merge(source_name: source[:name], selection: selection,
            selected: NodePolicy.selected?(source, row, selection))
        end
        { items: items, total: total, page: page, per_page: per_page }
      rescue ArgumentError, TypeError
        raise Failure.new('invalid_filter', 'Invalid pagination or node filter.')
      end

      def select_nodes(params)
        selected_profile = profile(Integer(params.fetch('profile_id')))
        selection = params['selection']
        raise Failure.new('invalid_selection', 'selection must be auto, include or exclude.') unless %w[auto include exclude].include?(selection)
        values = params.fetch('node_ids')
        raise Failure.new('invalid_nodes', 'Select between 1 and 200 nodes.') unless values.is_a?(Array) && (1..200).cover?(values.length)
        ids = values.map { |id| Integer(id) }.uniq
        source_ids = profile_dto(selected_profile)[:source_ids]
        raise Failure.new('invalid_nodes', 'Nodes must belong to the Profile Sources.') unless db[:nodes].where(id: ids, source_id: source_ids).count == ids.length
        db.transaction do
          ids.each do |node_id|
            ds = db[:node_selections].where(profile_id: selected_profile[:id], node_id: node_id)
            ds.delete
            db[:node_selections].insert(profile_id: selected_profile[:id], node_id: node_id, selection: selection) unless selection == 'auto'
          end
        end
        { updated: ids.length }
      rescue ArgumentError, TypeError, KeyError
        raise Failure.new('invalid_selection', 'Profile and node IDs are required integers.')
      end

      def merge(selected_profile)
        rows = profile_dto(selected_profile)[:source_ids].map { |id| sources.source(id) }
        selections = db[:node_selections].where(profile_id: selected_profile[:id]).all.to_h { |r| [r[:node_id], r[:selection]] }
        original = db[:nodes].where(source_id: rows.map { |r| r[:id] }, available: true).count
        proxies = rows.flat_map do |source|
          db[:nodes].where(source_id: source[:id]).order(:id).all.filter_map do |node|
            next unless NodePolicy.selected?(source, node, selections.fetch(node[:id], 'auto'))
            secret = %i[ciphertext iv tag].to_h { |key| [key, node["proxy_#{key}".to_sym]] }
            JSON.parse(@crypto.decrypt(secret)).merge('name' => source[:name_prefix] + node[:original_name])
          end
        end
        names = proxies.map { |p| p['name'] }
        raise Failure.new('duplicate_name', 'Duplicate node names; configure a unique Source prefix.') unless names.uniq.length == names.length
        raise Failure.new('empty_selection', 'No usable nodes selected; refresh Sources or adjust filters.') if proxies.empty?
        [{ 'proxies' => proxies }, { source_count: rows.length, original_node_count: original, selected_node_count: proxies.length }]
      end

      def build(id)
        selected_profile = profile(id)
        raise Failure.new('disabled_profile', 'Enable the Profile before building.') unless selected_profile[:enabled]
        record_id = db[:build_records].insert(profile_id: id, profile_name: selected_profile[:name], status: 'running', created_at: sources.now)
        begin
          document, stats = merge(selected_profile)
          db[:build_records].where(id: record_id).update(stats)
          path = File.join(data_root, 'cache', 'profile-builds', record_id.to_s, 'mihomo.yaml')
          config = Marshal.load(Marshal.dump(@config))
          config['provider'] = selected_profile[:provider]
          config['patches']['dns_profile'] = selected_profile[:dns_profile]
          config['outputs'] = ['mihomo']
          config['output'] = { 'mihomo' => path }
          final = BuildHelpers.with_private_logs { BuildPipeline.new(log: proc { |_| }).build(config, document: document) }
          db[:build_records].where(id: record_id).update(status: 'success', final_node_count: final[:proxies], artifact_path: path, finished_at: sources.now)
        rescue StandardError => e
          error = e.is_a?(Failure) ? e : Failure.new('build_failed', 'Build failed; check Provider compatibility, rules and local dependencies.')
          db[:build_records].where(id: record_id).update(status: 'failed', error_safe: error.message, finished_at: sources.now)
          raise error
        end
        build_dto(db[:build_records][id: record_id])
      end

      def build_dto(row)
        row.reject { |k, _| k == :artifact_path }
      end

      def builds
        db[:build_records].reverse_order(:id).limit(100).all.map { |row| build_dto(row) }
      end

      def publisher_status
        @publisher.status.reject { |k, _| k == :root }
      end

      def publish(id)
        row = db[:build_records][id: Integer(id)]
        raise Failure.new('invalid_build', 'A successful build is required.', 404) unless row && row[:status] == 'success'
        BuildHelpers.with_private_logs { @publisher.publish(row[:artifact_path]) }
      rescue ArgumentError, TypeError
        raise Failure.new('invalid_build', 'build_id must be an integer.')
      end

      def rollback
        @publisher.rollback
      end

      def tokens
        @publisher.list_tokens
      end

      def create_token(name, base_url)
        name = name.to_s
        raise Failure.new('invalid_token_name', 'Token name must contain 1–80 letters, numbers, spaces, dots, underscores or hyphens.') unless name.match?(/\A[\p{L}\p{N} ._-]{1,80}\z/u)
        uri = URI.parse(base_url.to_s)
        raise Failure.new('public_url_missing', 'Configure MPK_PUBLIC_BASE_URL with an HTTPS origin.') unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.query && !uri.fragment && ['', '/'].include?(uri.path)
        # Only the explicit create response contains the bearer URL. Token bytes
        # are never persisted in SQLite or returned from list/status.
        @publisher.create_token(name, public_base_url: base_url).reject { |key, _| key == :token }
      rescue URI::InvalidURIError
        raise Failure.new('public_url_invalid', 'Invalid HTTPS public origin.')
      end

      def revoke_token(name)
        { fingerprint: @publisher.revoke_token(name) }
      end

      def dashboard
        { source_count: db[:sources].count, node_count: db[:nodes].count,
          available_node_count: db[:nodes].where(available: true).count, profile_count: db[:profiles].count,
          publisher: publisher_status, recent_sources: sources.list.last(5), recent_builds: builds.first(5) }
      end
    end
  end
end
