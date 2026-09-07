# frozen_string_literal: true

require 'open3'
require 'shellwords'
require_relative 'build_helpers'

module MPK
  class ProviderRunner
    def initialize(root_dir:)
      @root_dir = root_dir
    end

    def run(manifest, input_path:, config: {})
      original = File.binread(input_path)
      kind = manifest.runner['kind'].to_s
      entry = manifest.runner['entrypoint']
      case kind
      when 'bash'
        env = provider_env(manifest, config)
        assignments = env.map { |k, v| "#{k}=#{Shellwords.escape(v)}" }.join(' ')
        command = "#{assignments} bash #{Shellwords.escape(BuildHelpers.bash_path_for(entry))} #{Shellwords.escape(BuildHelpers.bash_path_for(input_path))}"
        BuildHelpers.run_streaming({}, 'bash', '-c', command, log: "provider #{manifest.id}", exec_label: "provider #{manifest.id}")
      when 'ruby'
        env = provider_env(manifest, config)
        BuildHelpers.run_streaming(env, RbConfig.ruby, entry, input_path, log: "provider #{manifest.id}", exec_label: "provider #{manifest.id}")
      else
        raise Error, "unsupported runner kind: #{kind}"
      end
    rescue MPK::Error
      File.binwrite(input_path, original) if original
      raise
    rescue StandardError => e
      File.binwrite(input_path, original) if original
      raise Error, "provider #{manifest.id} failed: #{e.message}"
    end

    private

    def provider_env(manifest, config)
      opts = config['provider_options'].is_a?(Hash) ? config['provider_options'] : {}
      key = manifest.id.tr('-', '_')
      selected = opts[key].is_a?(Hash) ? opts[key] : {}
      merged = manifest.options.merge(selected)
      env = {}
      merged.each do |k, v|
        normalized = k.to_s
        normalized = 'provider_local' if normalized == 'local_script'
        normalized = 'provider_remote' if normalized == 'remote_url'
        value = v.to_s
        value = BuildHelpers.bash_path_for(value) if normalized == 'provider_local'
        env["MPK_#{normalized.upcase}"] = value
      end
      env
    end
  end
end
