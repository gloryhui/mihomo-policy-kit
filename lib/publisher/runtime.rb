# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'digest'
require 'securerandom'
require_relative 'build_id'

module MPK
  module Publisher
    # Publisher 运行目录。build 是 immutable；所有公开 token 目录都稳定地指向
    # 同一个 current symlink，因此一次 current 指针替换同时切换所有 token。
    #
    #   builds/<build-id>/mihomo.yaml + metadata.json  # immutable，staging 后原子进入
    #   current -> builds/<build-id>                   # 唯一的公开 active pointer
    #   previous -> builds/<build-id>                  # rollback 目标
    #   public/sub/<token> -> ../../current            # 稳定 token symlink（完整高熵 token）
    #
    # current 的 tmp symlink + rename 是唯一影响客户端的切换点。无论 promotion、
    # rollback 或切换后崩溃，所有 token 都由同一 current 解析，天然同时得到旧或新
    # immutable build；不需要逐 token reconcile。
    class Runtime
      BUILDS_DIR = 'builds'
      CURRENT_LINK = 'current'
      PREVIOUS_LINK = 'previous'
      PUBLIC_DIR = 'public'
      SUB_DIR = 'sub'
      CURRENT_VIEW = 'mihomo.yaml'
      STAGING_PREFIXES = ['.build-staging-', '.pointer-staging-'].freeze

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root.to_s)
      end

      def builds_dir = File.join(@root, BUILDS_DIR)
      def current_dir = File.join(@root, CURRENT_LINK)
      def previous_dir = File.join(@root, PREVIOUS_LINK)
      def current_yaml = File.join(current_dir, CURRENT_VIEW)
      def previous_yaml = File.join(previous_dir, CURRENT_VIEW)
      def public_dir = File.join(@root, PUBLIC_DIR)
      def sub_dir = File.join(public_dir, SUB_DIR)

      def init!
        [builds_dir, public_dir, sub_dir].each { |dir| FileUtils.mkdir_p(dir) }
        cleanup_stale_staging!
        @root
      end

      def initialized?
        File.directory?(builds_dir) && File.directory?(public_dir) && File.directory?(sub_dir)
      end

      def build_dir(build_id)
        File.join(builds_dir, build_id)
      end

      def build_yaml(build_id)
        File.join(build_dir(build_id), CURRENT_VIEW)
      end

      def build_metadata_path(build_id)
        File.join(build_dir(build_id), 'metadata.json')
      end

      def build_metadata(build_id)
        path = build_metadata_path(build_id)
        return nil unless File.file?(path)

        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue JSON::ParserError
        nil
      end

      # YAML、metadata、build_id 和 SHA256 都必须吻合才是可引用 build。
      def build_exists?(build_id)
        id = build_id.to_s
        return false if id.empty? || id.start_with?('.')

        valid_build_dir?(build_dir(id), id)
      end

      def list_builds
        return [] unless File.directory?(builds_dir)

        Dir.children(builds_dir).select { |id| build_exists?(id) }.sort
      end

      # 完整内容在 root 下隐藏 staging 写入并校验，再一次 rename 进入 builds。
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

      # current/previous 从各自 symlink 的受控 targets 解析；损坏/悬空 pointer 不被采信。
      def current_build_id = pointer_build_id(current_dir)
      def previous_build_id = pointer_build_id(previous_dir)
      def current_exists? = !current_build_id.nil?
      def previous_exists? = !previous_build_id.nil?

      # 所有 token 共享 current。previous 先替换，最后以一次 current symlink rename
      # 对客户端全局生效；若 final rename 失败则恢复 previous，current 从未改变。
      def promote!(build_id)
        raise MPK::Error, "build does not exist: #{build_id}" unless build_exists?(build_id)

        switch_current!(build_id, current_build_id)
        build_id
      end

      def rollback!
        current = current_build_id
        previous = previous_build_id
        raise MPK::Error, 'nothing to roll back: no previous build' unless previous

        switch_current!(previous, current)
        previous
      end

      def token_view_dir(token)
        File.join(sub_dir, token.to_s)
      end

      def subscription_yaml(token)
        File.join(token_view_dir(token), CURRENT_VIEW)
      end

      # token symlink 本身只在 create/revoke 改动。其 target 永远是 ../../current，
      # 所有 token 不参与 publish/rollback 的 N 次复制操作。
      def create_token_view(token)
        raise MPK::Error, 'cannot create token view: no current build' unless current_exists?

        target = File.join('..', '..', CURRENT_LINK)
        link = token_view_dir(token)
        tmp = File.join(sub_dir, ".token-staging-#{SecureRandom.hex(6)}")
        File.symlink(target, tmp)
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

      # 只接受 current/previous -> builds/<single-build-id>，防止指针逃逸 runtime。
      def pointer_build_id(pointer)
        return nil unless File.symlink?(pointer)

        target = File.realpath(pointer)
        return nil unless File.dirname(target) == File.realpath(builds_dir)

        id = File.basename(target)
        build_exists?(id) ? id : nil
      rescue SystemCallError
        nil
      end

      # 后一个参数是新 previous。只有 current pointer 决定公开内容，且它总是最后
      # 原子替换。previous 恢复失败不会删除/影响 current，原始错误仍会抛给调用者。
      def switch_current!(new_current, new_previous)
        original_previous = previous_build_id
        previous_changed = false
        begin
          if new_previous
            replace_pointer(previous_dir, new_previous)
            previous_changed = true
          else
            remove_pointer(previous_dir)
          end
          replace_pointer(current_dir, new_current)
        rescue StandardError => error
          restore_pointer(previous_dir, original_previous) if previous_changed || original_previous
          raise error
        end
      end

      # 同文件系统 tmp symlink -> rename。替换 current 时这是唯一全局公开切换点。
      def replace_pointer(pointer, build_id)
        raise MPK::Error, "build does not exist: #{build_id}" unless build_exists?(build_id)

        tmp = staging_dir('.pointer-staging-')
        File.symlink(File.join(BUILDS_DIR, build_id), tmp)
        atomic_rename(tmp, pointer)
      ensure
        FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
      end

      def restore_pointer(pointer, build_id)
        build_id ? replace_pointer(pointer, build_id) : remove_pointer(pointer)
      rescue StandardError
        # Preserve the original switch exception. current remains a complete immutable build.
      end

      def remove_pointer(pointer)
        FileUtils.rm_f(pointer) if File.symlink?(pointer) || File.file?(pointer)
      end

      def atomic_rename(source, target)
        File.rename(source, target)
      end

      def cleanup_stale_staging!
        STAGING_PREFIXES.each do |prefix|
          Dir.glob(File.join(@root, "#{prefix}*")).each do |path|
            FileUtils.rm_rf(path) if File.exist?(path)
          end
        end
      end

      def staging_dir(prefix)
        File.join(@root, "#{prefix}#{SecureRandom.hex(6)}")
      end
    end
  end
end
