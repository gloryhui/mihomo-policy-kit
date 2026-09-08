# frozen_string_literal: true

require 'fileutils'
require 'tempfile'

require_relative 'output_adapters/base'
require_relative 'output_adapters/mihomo'
require_relative 'output_adapters/stash'
require_relative 'output_adapters/loon'
require_relative 'output_adapters/surge'
require_relative 'output_adapters/sing_box'

module MPK
  # Small fixed registry for V0.4 output targets.  Adapters receive the same
  # validated normalized policy; client-specific conversion never leaks back
  # into Provider or Overlay code.
  class OutputRegistry
    ADAPTERS = {
      'mihomo' => OutputAdapters::Mihomo,
      'stash' => OutputAdapters::Stash,
      'loon' => OutputAdapters::Loon,
      'surge' => OutputAdapters::Surge,
      'sing-box' => OutputAdapters::SingBox
    }.freeze

    DEFAULT_PATHS = {
      'mihomo' => './dist/mihomo.yaml',
      'stash' => './dist/stash.yaml',
      'loon' => './dist/loon.conf',
      'surge' => './dist/surge.conf',
      'sing-box' => './dist/sing-box.json'
    }.freeze

    def fetch(id)
      name = id.to_s.strip
      adapter = ADAPTERS[name]
      raise Error, "unknown output adapter: #{name}" if adapter.nil?

      adapter.new
    end

    def selected(config)
      value = config['outputs']
      values = value.nil? ? ['mihomo'] : Array(value)
      raise Error, 'outputs must contain at least one output adapter' if values.empty?

      values.map(&:to_s).map(&:strip).each { |id| fetch(id) }.then { |ids| ids.uniq }
    end

    def output_path(config, id)
      configured = config.dig('output', id).to_s.strip
      configured = DEFAULT_PATHS.fetch(id) if configured.empty?
      BuildHelpers.absolute(configured)
    end
  end

  module OutputPipeline
    module_function

    # Render and validate every requested artifact before writing any of them.
    # Thus an incompatible later adapter cannot overwrite an earlier good file.
    def render_all(policy, config)
      registry = OutputRegistry.new
      registry.selected(config).map do |id|
        adapter = registry.fetch(id)
        content = adapter.render(policy)
        # Validate every rendered representation before any existing artifact is
        # promoted.  This is intentionally separate from write: a malformed
        # later client output must not replace an earlier good artifact.
        adapter.validate(content)
        [adapter, content, registry.output_path(config, id)]
      end
    end

    def write_all(rendered)
      # Phase 1: stage every candidate in its target directory (no promotion).
      staged = rendered.map do |adapter, content, path|
        candidate = stage_candidate(adapter, content, path)
        [adapter, candidate, path]
      end

      begin
        # Phase 2: run core validation on every staged candidate (e.g.
        # `mihomo -t`) before any promotion, so a failing core check cannot
        # leave a partial update across the selected outputs.
        staged.each { |adapter, candidate, _path| adapter.validate_core(candidate) }

        # Phase 3: promote all candidates only after every core check passed.
        staged.each { |_adapter, candidate, path| BuildHelpers.promote_file(candidate, path) }
      ensure
        # Remove any candidate that was not promoted (promote_file moves it away).
        staged.each do |_adapter, candidate, _path|
          File.delete(candidate) if File.file?(candidate)
        end
      end
    end

    # Write a rendered artifact to a same-directory candidate file without
    # promoting it, so core validation can run before any existing output is
    # replaced.
    def stage_candidate(adapter, content, path)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = Tempfile.create(['mpk-candidate-', adapter.extension], File.dirname(path))
      tmp.binmode
      tmp.write(content)
      tmp.flush
      tmp.fsync
      tmp.close if tmp.respond_to?(:close) && !tmp.closed?
      tmp.path
    end
  end
end
