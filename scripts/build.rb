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
require 'output_adapter'
require 'services/build_pipeline'

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

  MPK::Services::BuildPipeline.new.build(config)
rescue MPK::Error => e
  warn "[ERROR] #{e.message}"
  exit 1
rescue StandardError => e
  warn "[ERROR] unexpected #{e.class}: #{e.message}"
  warn e.backtrace.join("\n") if ENV['MPK_DEBUG'] == '1'
  exit 1
end
