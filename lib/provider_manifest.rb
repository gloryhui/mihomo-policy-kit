# frozen_string_literal: true

require 'yaml'
require_relative 'overlay'

module MPK
  ProviderManifest = Struct.new(:id, :input_format, :output_format, :runner, :group_map, :options, :path, keyword_init: true)

  class ManifestLoader
    REQUIRED = %w[id input_format output_format runner group_map].freeze

    def initialize(root_dir:)
      @root_dir = root_dir
    end

    def load(provider_id, configured_path: nil)
      id = provider_id.to_s.strip
      raise Error, 'provider id is required' if id.empty?
      path = configured_path.to_s.strip
      path = File.join(@root_dir, 'providers', id, 'manifest.yaml') if path.empty?
      path = File.expand_path(path, @root_dir)
      raise Error, "provider manifest not found: #{id}" unless File.file?(path)
      raw = YAML.safe_load(File.read(path, encoding: 'UTF-8'), aliases: true) || {}
      raise Error, "provider manifest must be a mapping: #{id}" unless raw.is_a?(Hash)
      missing = REQUIRED.reject { |k| raw.key?(k) }
      raise Error, "provider manifest missing fields: #{missing.join(', ')}" unless missing.empty?
      raise Error, "provider id mismatch: #{raw['id']} != #{id}" unless raw['id'].to_s == id
      %w[input_format output_format].each do |key|
        raise Error, "unsupported #{key}: #{raw[key]}" unless raw[key].to_s == 'mihomo-yaml'
      end
      runner = raw['runner']
      raise Error, "provider runner must be a mapping: #{id}" unless runner.is_a?(Hash)
      kind = runner['kind'].to_s
      raise Error, "unsupported runner kind: #{kind}" unless %w[bash ruby].include?(kind)
      entrypoint = runner['entrypoint'].to_s
      raise Error, "provider entrypoint missing: #{id}" if entrypoint.empty?
      entry = File.expand_path(entrypoint, File.dirname(path))
      raise Error, "provider entrypoint not found: #{id}" unless File.file?(entry)
      group_map = File.expand_path(raw['group_map'].to_s, File.dirname(path))
      raise Error, "provider group map not found: #{id}" unless File.file?(group_map)
      groups = YAML.safe_load(File.read(group_map, encoding: 'UTF-8'), aliases: true)
      raise Error, "provider group map must be a mapping: #{id}" unless groups.is_a?(Hash)
      ProviderManifest.new(id: id, input_format: raw['input_format'], output_format: raw['output_format'],
                           runner: runner.merge('entrypoint' => entry), group_map: group_map,
                           options: raw['options'].is_a?(Hash) ? raw['options'] : {}, path: path)
    rescue Psych::Exception => e
      raise Error, "invalid provider manifest #{id}: #{e.message}"
    end
  end
end
