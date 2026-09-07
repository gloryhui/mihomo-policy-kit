# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'digest'
require 'securerandom'
require_relative 'build_id'

module MPK
  module Publisher
    # Immutable build + immutable state-set runtime.
    #
    #   builds/<build-id>/...                         # complete immutable artifacts
    #   states/<state-id>/{state.json,current,previous} # immutable {current,previous} pair
    #   active -> states/<state-id>                    # single atomic state commit point
    #   public/sub/<token> -> ../../active/current     # stable full-token URL view
    #
    # A new state-set is complete before it is made active. Replacing active with one
    # symlink rename therefore switches current and previous together, and every token
    # resolves through exactly that same point.
    class Runtime
      BUILDS_DIR = 'builds'
      STATES_DIR = 'states'
      ACTIVE_LINK = 'active'
      CURRENT_LINK = 'current'
      PREVIOUS_LINK = 'previous'
      PUBLIC_DIR = 'public'
      SUB_DIR = 'sub'
      CURRENT_VIEW = 'mihomo.yaml'
      STAGING_PREFIXES = ['.build-staging-', '.state-staging-', '.active-staging-', '.token-staging-'].freeze

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root.to_s)
      end

      def builds_dir = File.join(@root, BUILDS_DIR)
      def states_dir = File.join(@root, STATES_DIR)
      def active_dir = File.join(@root, ACTIVE_LINK)
      def current_dir = File.join(active_dir, CURRENT_LINK)
      def previous_dir = File.join(active_dir, PREVIOUS_LINK)
      def current_yaml = File.join(current_dir, CURRENT_VIEW)
      def previous_yaml = File.join(previous_dir, CURRENT_VIEW)
      def public_dir = File.join(@root, PUBLIC_DIR)
      def sub_dir = File.join(public_dir, SUB_DIR)

      def init!
        [builds_dir, states_dir, public_dir, sub_dir].each { |dir| FileUtils.mkdir_p(dir) }
        cleanup_stale_staging!
        @root
      end

      def initialized?
        [builds_dir, states_dir, public_dir, sub_dir].all? { |dir| File.directory?(dir) }
      end

      def build_dir(build_id) = File.join(builds_dir, build_id)
      def build_yaml(build_id) = File.join(build_dir(build_id), CURRENT_VIEW)
      def build_metadata_path(build_id) = File.join(build_dir(build_id), 'metadata.json')

      def build_metadata(build_id)
        path = build_metadata_path(build_id)
        return nil unless File.file?(path)

        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue JSON::ParserError
        nil
      end

      def build_exists?(build_id)
        id = build_id.to_s
        return false if id.empty? || id.start_with?('.')

        valid_build_dir?(build_dir(id), id)
      end

      def list_builds
        return [] unless File.directory?(builds_dir)

        Dir.children(builds_dir).select { |id| build_exists?(id) }.sort
      end

      # Artifacts become visible in builds only via one same-filesystem directory rename.
      def commit_build(build_id, content_yaml, metadata)
        return build_id if build_exists?(build_id)

        staging = staging_dir('.build-staging-')
        begin
          FileUtils.mkdir_p(staging)
          File.binwrite(File.join(staging, CURRENT_VIEW), content_yaml)
          File.write(File.join(staging, 'metadata.json'), JSON.pretty_generate(metadata))
          raise MPK::Error, "staging incomplete or invalid for build: #{build_id}" unless valid_build_dir?(staging, build_id.to_s)

          atomic_rename(staging, build_dir(build_id))
          staging = nil
        ensure
          FileUtils.rm_rf(staging) if staging && File.exist?(staging)
        end
        build_id
      end

      # The pair comes from one active immutable state-set, never two independently
      # mutable pointers. Invalid/corrupt active targets are treated as no state.
      def active_state
        state = active_state_dir
        return { 'current' => nil, 'previous' => nil } unless state

        payload = JSON.parse(File.read(File.join(state, 'state.json'), encoding: 'UTF-8'))
        current = payload['current']
        previous = payload['previous']
        return { 'current' => nil, 'previous' => nil } unless build_exists?(current)
        return { 'current' => nil, 'previous' => nil } if previous && !build_exists?(previous)
        return { 'current' => nil, 'previous' => nil } unless state_pointer_matches?(state, CURRENT_LINK, current)
        return { 'current' => nil, 'previous' => nil } if previous && !state_pointer_matches?(state, PREVIOUS_LINK, previous)
        return { 'current' => nil, 'previous' => nil } if previous.nil? && File.exist?(File.join(state, PREVIOUS_LINK))

        { 'current' => current, 'previous' => previous }
      rescue JSON::ParserError, TypeError, SystemCallError
        { 'current' => nil, 'previous' => nil }
      end

      def current_build_id = active_state['current']
      def previous_build_id = active_state['previous']
      def current_exists? = !current_build_id.nil?
      def previous_exists? = !previous_build_id.nil?

      def promote!(build_id)
        raise MPK::Error, "build does not exist: #{build_id}" unless build_exists?(build_id)

        before = active_state
        state_id = create_state_set(build_id, before['current'])
        activate_state_set(state_id)
        build_id
      end

      def rollback!
        before = active_state
        raise MPK::Error, 'nothing to roll back: no previous build' unless before['previous']

        state_id = create_state_set(before['previous'], before['current'])
        activate_state_set(state_id)
        before['previous']
      end

      def token_view_dir(token) = File.join(sub_dir, token.to_s)
      def subscription_yaml(token) = File.join(token_view_dir(token), CURRENT_VIEW)

      # Token links are stable after creation; only active changes during promotion.
      def create_token_view(token)
        raise MPK::Error, 'cannot create token view: no current build' unless current_exists?

        link = token_view_dir(token)
        tmp = File.join(sub_dir, ".token-staging-#{SecureRandom.hex(6)}")
        File.symlink(File.join('..', '..', ACTIVE_LINK, CURRENT_LINK), tmp)
        atomic_rename(tmp, link)
        true
      rescue NotImplementedError, SystemCallError
        false
      ensure
        FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
      end

      def token_view?(token)
        File.symlink?(token_view_dir(token)) && File.file?(subscription_yaml(token))
      end

      def remove_token_view(token)
        FileUtils.rm_rf(token_view_dir(token))
      end

      def subscription_source_path(token)
        return nil unless token_view?(token)

        current = current_build_id
        current && build_yaml(current)
      end

      private

      def valid_build_dir?(dir, build_id)
        yaml = File.join(dir, CURRENT_VIEW)
        metadata_path = File.join(dir, 'metadata.json')
        return false unless File.file?(yaml) && File.file?(metadata_path)

        metadata = JSON.parse(File.read(metadata_path, encoding: 'UTF-8'))
        sha256 = metadata['sha256']
        metadata.is_a?(Hash) && metadata['build_id'] == build_id &&
          sha256.is_a?(String) && sha256.match?(/\A[0-9a-f]{64}\z/) &&
          Digest::SHA256.file(yaml).hexdigest == sha256
      rescue JSON::ParserError, TypeError, SystemCallError
        false
      end

      def active_state_dir
        return nil unless File.symlink?(active_dir)

        target = File.realpath(active_dir)
        return nil unless File.dirname(target) == File.realpath(states_dir)
        return nil unless File.directory?(target)

        target
      rescue SystemCallError
        nil
      end

      def state_pointer_matches?(state_dir, name, build_id)
        pointer = File.join(state_dir, name)
        return false unless File.symlink?(pointer)

        File.realpath(pointer) == File.realpath(build_dir(build_id))
      rescue SystemCallError
        false
      end

      # State directory is immutable and fully validated before active is touched.
      def create_state_set(current, previous)
        raise MPK::Error, "build does not exist: #{current}" unless build_exists?(current)
        raise MPK::Error, "build does not exist: #{previous}" if previous && !build_exists?(previous)

        state_id = SecureRandom.hex(16)
        staging = state_staging_dir
        begin
          FileUtils.mkdir_p(staging)
          write_state_pointer(staging, CURRENT_LINK, current)
          write_state_pointer(staging, PREVIOUS_LINK, previous) if previous
          File.write(File.join(staging, 'state.json'), JSON.pretty_generate('current' => current, 'previous' => previous))
          raise MPK::Error, 'state staging incomplete' unless valid_state_set?(staging, current, previous)

          atomic_rename(staging, File.join(states_dir, state_id))
          staging = nil
          state_id
        ensure
          FileUtils.rm_rf(staging) if staging && File.exist?(staging)
        end
      end

      def valid_state_set?(dir, current, previous)
        payload = JSON.parse(File.read(File.join(dir, 'state.json'), encoding: 'UTF-8'))
        payload['current'] == current && payload['previous'] == previous &&
          state_pointer_matches?(dir, CURRENT_LINK, current) &&
          (!previous || state_pointer_matches?(dir, PREVIOUS_LINK, previous)) &&
          (previous || !File.exist?(File.join(dir, PREVIOUS_LINK)))
      rescue JSON::ParserError, TypeError, SystemCallError
        false
      end

      def write_state_pointer(dir, name, build_id)
        File.symlink(File.join('..', '..', BUILDS_DIR, build_id), File.join(dir, name))
      end

      # The one and only commit point for the full {current, previous} transaction.
      def activate_state_set(state_id)
        state = File.join(states_dir, state_id)
        raise MPK::Error, "state does not exist: #{state_id}" unless File.directory?(state)

        tmp = staging_dir('.active-staging-')
        File.symlink(File.join(STATES_DIR, state_id), tmp)
        atomic_rename(tmp, active_dir)
      ensure
        FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
      end

      def atomic_rename(source, target)
        File.rename(source, target)
      end

      def cleanup_stale_staging!
        STAGING_PREFIXES.each do |prefix|
          base = prefix == '.state-staging-' ? states_dir : @root
          Dir.glob(File.join(base, "#{prefix}*")).each do |path|
            FileUtils.rm_rf(path) if File.exist?(path)
          end
        end
      end

      def state_staging_dir
        File.join(states_dir, ".state-staging-#{SecureRandom.hex(6)}")
      end

      def staging_dir(prefix)
        File.join(@root, "#{prefix}#{SecureRandom.hex(6)}")
      end
    end
  end
end
