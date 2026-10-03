# frozen_string_literal: true

require_relative '../build_helpers'
require_relative '../provider_manifest'
require_relative '../provider_runner'
require_relative '../output_adapter'

module MPK
  module Services
    # The CLI and Profile service share this compiler. Source resolution remains
    # separate from Provider/Overlay/Output and Web DTOs never enter the compiler.
    class BuildPipeline
      def initialize(root_dir: BuildHelpers::ROOT_DIR, log: nil)
        @root_dir, @log = root_dir, log || proc { |line| puts line }
      end

      def build(config, document: nil)
        manifest = MPK::ManifestLoader.new(root_dir: @root_dir).load(config['provider'].to_s.strip,
          configured_path: BuildHelpers.dig(config, 'provider_manifest'))
        override = BuildHelpers.dig(config, 'groups', 'map_file').to_s
        map_path = override.empty? ? manifest.group_map : BuildHelpers.absolute(override)
        overlay = MPK::Overlay.new(config: config, group_map: MPK::YAMLUtil.load_file(map_path))
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
          overlay.apply!(transformed, root_dir: @root_dir)
          stats = overlay.validate!(transformed, source_proxy_count: source_count)
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
