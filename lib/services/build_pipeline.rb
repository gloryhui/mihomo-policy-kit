# frozen_string_literal: true

require_relative '../build_helpers'
require_relative '../provider_manifest'
require_relative '../provider_runner'
require_relative '../output_adapter'
require_relative '../personal_policy'

module MPK
  module Services
    # The CLI and Profile service share this compiler. Source resolution remains
    # separate from Provider/Overlay/Output and Web DTOs never enter the compiler.
    class BuildPipeline
      def initialize(root_dir: BuildHelpers::ROOT_DIR, log: nil)
        @root_dir, @log = root_dir, log || proc { |line| puts line }
      end

      def build(config, document: nil, policy_documents: nil)
        preset = config.fetch('policy_preset', 'default')
        raise MPK::Error, 'unknown policy preset' unless %w[default three-source-ai].include?(preset)
        ai = nil
        if preset == 'three-source-ai'
          raise MPK::Error, 'three-source policy requires Smart-Config-Kit Normal and Mihomo output' unless config['provider'] == 'smart-config-kit' && Array(config.fetch('outputs', ['mihomo'])) == ['mihomo']
          document, ai = PersonalPolicy.prepare(policy_documents)
          core = PersonalPolicy.find_core(config.fetch('policy_runtime', {}))
        end
        manifest = MPK::ManifestLoader.new(root_dir: @root_dir).load(config['provider'].to_s.strip,
          configured_path: BuildHelpers.dig(config, 'provider_manifest'))
        override = BuildHelpers.dig(config, 'groups', 'map_file').to_s
        map_path = override.empty? ? manifest.group_map : BuildHelpers.absolute(override)
        group_map = MPK::YAMLUtil.load_file(map_path)
        group_map['ai'] = PersonalPolicy::GROUPS.fetch('category-ai-!cn') if ai
        overlay = MPK::Overlay.new(config: config, group_map: group_map)
        Dir.mktmpdir('mihomo-policy-kit-') do |work_dir|
          input = File.join(work_dir, 'source.yaml')
          if document
            File.binwrite(input, YAML.dump(document))
          else
            source_file = BuildHelpers.dig(config, 'source', 'file')
            if source_file && !source_file.to_s.strip.empty?
              source_path = BuildHelpers.absolute(source_file)
              raise MPK::Error, "source file not found: #{source_path}" unless File.file?(source_path)
              @log.call("[source] use local file: #{source_path}")
              FileUtils.cp(source_path, input)
            else
              env_name = BuildHelpers.dig(config, 'source', 'url_env', default: 'MPK_SOURCE_URL').to_s
              url = ENV[env_name].to_s.strip
              raise MPK::Error, "environment variable #{env_name} is empty" if url.empty?
              @log.call("[source] download subscription from #{env_name}")
              BuildHelpers.fetch_to(url, input, log: "$#{env_name}")
            end
          end
          format, uri_count = BuildHelpers.normalize_subscription_file(input)
          @log.call("[source] format=#{format}")
          source = MPK::YAMLUtil.load_file(input)
          source_count = Array(source['proxies']).length
          providers = source['proxy-providers'].is_a?(Hash) ? source['proxy-providers'].length : 0
          source_count = uri_count if format == :uri_list && source_count.zero?
          @log.call("[source] proxies=#{source_count} proxy-providers=#{providers}")
          raise MPK::Error, 'source subscription contains neither proxies nor proxy-providers' if source_count.zero? && providers.zero?
          MPK::ProviderRunner.new(root_dir: @root_dir).run(manifest, input_path: input, config: config)
          transformed = MPK::YAMLUtil.load_file(input)
          after_count = Array(transformed['proxies']).length
          @log.call("[provider] proxies after transform=#{after_count}")
          raise MPK::Error, "provider removed all proxies: source=#{source_count}, transformed=0" if source_count.positive? && after_count.zero?
          raise MPK::Error, 'personal policy provider changed the ordinary node count' if ai && after_count != source_count
          PersonalPolicy.apply!(transformed, ai) if ai
          overlay.apply!(transformed, root_dir: @root_dir)
          PersonalPolicy.validate!(transformed) if ai
          stats = overlay.validate!(transformed, source_proxy_count: source_count)
          if ai
            PersonalPolicy.write_private(input, YAML.dump(transformed))
            cache = config.dig('policy_runtime', 'geodata_dir')
            %w[geoip.dat geosite.dat country.mmdb ASN.mmdb].each do |file|
              cached = File.join(cache.to_s, file)
              FileUtils.cp(cached, File.join(work_dir, file)) if cache && File.file?(cached)
            end
            PersonalPolicy.run!(core, '-t', '-d', work_dir, '-f', input, seconds: 180, label: 'mihomo configuration validation')
          end
          outputs = MPK::OutputPipeline.render_all(transformed, config)
          MPK::OutputPipeline.write_all(outputs)
          @log.call('[build] success')
          outputs.each { |adapter, _, path| @log.call("[build] output #{adapter.id}=#{path}") }
          @log.call("[build] proxies=#{stats[:proxies]} proxy-providers=#{stats[:proxy_providers]} proxy-groups=#{stats[:proxy_groups]} rules=#{stats[:rules]}")
          stats
        end
      end
    end
  end
end
