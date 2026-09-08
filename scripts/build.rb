# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'tmpdir'

ROOT_DIR = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT_DIR, 'lib'))
require 'overlay'
require 'build_helpers'
require 'provider_manifest'
require 'provider_runner'

begin
  config_path = ARGV[0] || File.join(ROOT_DIR, 'config', 'config.yaml')
  config_path = BuildHelpers.absolute(config_path) unless config_path.start_with?('/')
  raise MPK::Error, "config not found: #{config_path}\ncopy config/config.example.yaml to config/config.yaml first" unless File.file?(config_path)
  config = BuildHelpers.load_config(config_path)
  dns_override = ARGV[1].to_s
  unless dns_override.empty?
    config['patches'] = {} unless config['patches'].is_a?(Hash)
    config['patches']['dns_profile'] = dns_override
  end
  output_override = ARGV[2].to_s
  unless output_override.empty?
    config['output'] = {} unless config['output'].is_a?(Hash)
    config['output']['mihomo'] = output_override
  end

  provider_name = config['provider'].to_s.strip
  manifest = MPK::ManifestLoader.new(root_dir: ROOT_DIR).load(provider_name,
    configured_path: BuildHelpers.dig(config, 'provider_manifest'))
  configured_group_map = BuildHelpers.dig(config, 'groups', 'map_file').to_s
  group_map_path = configured_group_map.empty? ? manifest.group_map : BuildHelpers.absolute(configured_group_map)
  group_map = MPK::YAMLUtil.load_file(group_map_path)
  overlay = MPK::Overlay.new(config: config, group_map: group_map)

  Dir.mktmpdir('mihomo-policy-kit-') do |work_dir|
    working_yaml = File.join(work_dir, 'source.yaml')
    source_file = BuildHelpers.dig(config, 'source', 'file')
    if source_file && !source_file.to_s.strip.empty?
      source_path = BuildHelpers.absolute(source_file)
      raise MPK::Error, "source file not found: #{source_path}" unless File.file?(source_path)
      puts "[source] use local file: #{source_path}"
      FileUtils.cp(source_path, working_yaml)
    else
      env_name = BuildHelpers.dig(config, 'source', 'url_env', default: 'MPK_SOURCE_URL').to_s
      source_url = ENV[env_name].to_s.strip
      raise MPK::Error, "environment variable #{env_name} is empty" if source_url.empty?
      puts "[source] download subscription from #{env_name}"
      BuildHelpers.fetch_to(source_url, working_yaml, log: "$#{env_name}")
    end

    source_format, uri_count = BuildHelpers.normalize_subscription_file(working_yaml)
    puts "[source] format=#{source_format}"
    source_document = MPK::YAMLUtil.load_file(working_yaml)
    source_proxy_count = Array(source_document['proxies']).length
    source_provider_count = source_document['proxy-providers'].is_a?(Hash) ? source_document['proxy-providers'].length : 0
    source_proxy_count = uri_count if source_format == :uri_list && source_proxy_count.zero?
    puts "[source] proxies=#{source_proxy_count} proxy-providers=#{source_provider_count}"
    raise MPK::Error, 'source subscription contains neither proxies nor proxy-providers' if source_proxy_count.zero? && source_provider_count.zero?

    MPK::ProviderRunner.new(root_dir: ROOT_DIR).run(manifest, input_path: working_yaml, config: config)
    transformed = MPK::YAMLUtil.load_file(working_yaml)
    after_provider_proxy_count = Array(transformed['proxies']).length
    puts "[provider] proxies after transform=#{after_provider_proxy_count}"
    if source_proxy_count.positive? && after_provider_proxy_count.zero?
      raise MPK::Error, "provider removed all proxies: source=#{source_proxy_count}, transformed=0"
    end

    overlay.apply!(transformed, root_dir: ROOT_DIR)
    stats = overlay.validate!(transformed, source_proxy_count: source_proxy_count)
    output_path = BuildHelpers.absolute(BuildHelpers.dig(config, 'output', 'mihomo', default: './dist/mihomo.yaml'))
    BuildHelpers.write_and_test(transformed, output_path)
    puts '[build] success'
    puts "[build] output=#{output_path}"
    puts "[build] proxies=#{stats[:proxies]} proxy-providers=#{stats[:proxy_providers]} proxy-groups=#{stats[:proxy_groups]} rules=#{stats[:rules]}"
  end
rescue MPK::Error => e
  warn "[ERROR] #{e.message}"
  exit 1
rescue StandardError => e
  warn "[ERROR] unexpected #{e.class}: #{e.message}"
  warn e.backtrace.join("\n") if ENV['MPK_DEBUG'] == '1'
  exit 1
end
