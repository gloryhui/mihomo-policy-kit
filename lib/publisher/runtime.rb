# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'digest'
require 'time'
require 'securerandom'
require_relative 'build_id'

module MPK
  module Publisher
    # Publisher 运行目录（publish root）模型与状态管理。
    #
    # 布局：
    #
    #   <root>/
    #     builds/<build-id>/mihomo.yaml + metadata.json   # immutable 版本（staging 后原子进入）
    #     active-state.json                               # 单一原子指针（current/previous 唯一事实源）
    #     public/sub/<token>/mihomo.yaml                  # 真实文件视图（跟随 current，原子覆盖）
    #     token-state/<fingerprint>.json                  # token 元数据（含完整 token，敏感）
    #
    # 原子性与可观察一致性（Issue #11 + Sol Review 两轮 P0）：
    #   - build 一旦完整写入后 immutable，从不被修改；build 目录通过
    #     “.build-staging-* 写完整 -> 一次 atomic rename 进入 builds/”落盘，
    #     进程在写 YAML / metadata 中途崩溃最多遗留 staging，不会污染 builds/。
    #   - current / previous 通过单一 `active-state.json` 表达：
    #     { "current": <build-id>, "previous": <build-id> | null }。
    #     整个文件用“写 tmp + rename”单点原子替换：任何时刻读取该文件都得到
    #     完整一致的 (current, previous)，不存在多目录 rename 的中间消失窗口。
    #   - 客户端稳定 URL public/sub/<token>/mihomo.yaml 是真实文件，内容为
    #     当前 current build 的完整 YAML 拷贝。promote / rollback 后每个视图用
    #     “写 tmp + rename 覆盖”原子更新：目标路径从不被删除，任何时刻打开都
    #     成功，读到的是旧版或新版完整内容（绝不 404 / 缺失 / 半成品）。
    #   - 逻辑状态（active-state.json）先切换，token 视图随后逐文件原子追赶；
    #     中途崩溃只会留下“状态新 / 视图旧”的缓存滞后，下一次 init!/操作会用
    #     当前 current 自愈刷新所有 token 视图，不破坏任何 good state。
    #   - rollback 只改 active 指针与视图内容，不修改 builds/ 里任何文件。
    class Runtime
      BUILDS_DIR = 'builds'
      PUBLIC_DIR = 'public'
      SUB_DIR = 'sub'
      ACTIVE_FILE = 'active-state.json'
      CURRENT_VIEW = 'mihomo.yaml'
      STAGING_PREFIXES = ['.build-staging-', '.view-tmp-'].freeze

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root.to_s)
      end

      def builds_dir = File.join(@root, BUILDS_DIR)
      def public_dir = File.join(@root, PUBLIC_DIR)
      def sub_dir = File.join(public_dir, SUB_DIR)
      def active_file = File.join(@root, ACTIVE_FILE)

      # 初始化运行目录（幂等）：创建空骨架、清理陈旧 staging、自愈滞后的 token 视图。
      def init!
        [builds_dir, public_dir, sub_dir].each { |dir| FileUtils.mkdir_p(dir) }
        cleanup_stale_staging!
        reconcile_public_views!
        @root
      end

      def initialized?
        File.directory?(builds_dir) && File.directory?(public_dir) && File.directory?(sub_dir)
      end

      # ------------------------------------------------------------------
      # builds（immutable；staging -> 原子 rename 进入）
      # ------------------------------------------------------------------

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

      # build 完整 = YAML 存在、metadata 可解析、build_id 匹配，且 metadata 中的
      # SHA256 与实际 YAML 完全相符。仅有一个文件、损坏/错配 metadata 的目录均是
      # 无效残留，绝不参与 list_builds、幂等复用或 promote。
      def build_exists?(build_id)
        id = build_id.to_s
        return false if id.empty? || id.start_with?('.')

        valid_build_dir?(build_dir(id), id)
      end

      # 列出 builds 下所有完整 build-id。
      def list_builds
        return [] unless File.directory?(builds_dir)

        Dir.children(builds_dir).select { |id| build_exists?(id) }.sort
      end

      # 把完整 YAML + metadata 原子写入 builds/<build-id>。
      # 先在 .build-staging-* 写完整，再整体 rename 一次进入 builds/。
      # 已存在完整 build 时幂等返回；半成品残留绝不被当作 build。
      def commit_build(build_id, content_yaml, metadata)
        return build_id if build_exists?(build_id)

        staging = staging_dir('.build-staging-')
        begin
          FileUtils.mkdir_p(staging)
          File.binwrite(File.join(staging, CURRENT_VIEW), content_yaml)
          File.write(File.join(staging, 'metadata.json'), JSON.pretty_generate(metadata))
          # 完整性确认：rename 前必须是可独立验证的完整合法 build。
          unless valid_build_dir?(staging, build_id.to_s)
            raise MPK::Error, "staging incomplete or invalid for build: #{build_id}"
          end
          FileUtils.mkdir_p(builds_dir)
          atomic_rename(staging, build_dir(build_id)) # 同文件系统一次原子 rename
          staging = nil
        ensure
          FileUtils.rm_rf(staging) if staging && File.exist?(staging)
        end
        build_id
      end

      # ------------------------------------------------------------------
      # active 指针（current / previous 唯一事实源）
      # ------------------------------------------------------------------

      # 返回 { 'current' => build-id|nil, 'previous' => build-id|nil }。
      # 读取到不完整/损坏文件时按“无状态”处理（不抛出，保证可用性）。
      def active_state
        return { 'current' => nil, 'previous' => nil } unless File.file?(active_file)

        parsed = JSON.parse(File.read(active_file, encoding: 'UTF-8'))
        {
          'current' => parsed['current'],
          'previous' => parsed['previous']
        }
      rescue JSON::ParserError, TypeError
        { 'current' => nil, 'previous' => nil }
      end

      def current_build_id
        id = active_state['current']
        id && build_exists?(id) ? id : nil
      end

      def previous_build_id
        id = active_state['previous']
        id && build_exists?(id) ? id : nil
      end

      def current_exists?
        !current_build_id.nil?
      end

      def previous_exists?
        !previous_build_id.nil?
      end

      # promote：把已完整 build 提升为 current。
      #   1. （build 已由 commit_build 原子进入 builds/）
      #   2. 原子替换 active-state.json：current=build_id, previous=旧 current
      #   3. 逐个原子刷新 token 视图到新内容
      # 任一步失败都不破坏“已就位的 good state”：active 切换后崩溃只留下视图滞后，
      # 自愈会补齐；active 切换前失败则线上完全不变。
      def promote!(build_id)
        raise MPK::Error, "build does not exist: #{build_id}" unless build_exists?(build_id)

        original = active_state
        new_previous = original['current'] && original['current'] != build_id ? original['current'] : original['previous']
        write_active('current' => build_id, 'previous' => new_previous)
        refresh_public_views(build_id)
        build_id
      rescue StandardError => error
        # active 切换成功但某个 token 视图刷新失败时，恢复原 active 指针并尽力把
        # 已刷新视图写回旧内容。每一步都是单文件原子替换，因此客户端只会看到
        # old/new 完整内容，绝不会看到路径缺失或半成品。
        restore_after_view_refresh_failure(original) if defined?(original) && original
        raise error
      end

      # rollback：current 与 previous 互换（只改 active 指针与 token 视图）。
      def rollback!
        original = active_state
        cur = original['current']
        prev = original['previous']
        raise MPK::Error, 'nothing to roll back: no previous build' unless prev && build_exists?(prev)

        write_active('current' => prev, 'previous' => cur)
        refresh_public_views(prev)
        prev
      rescue StandardError => error
        restore_after_view_refresh_failure(original) if defined?(original) && original
        raise error
      end

      # ------------------------------------------------------------------
      # token 公开视图（真实文件，跟随 current）
      # ------------------------------------------------------------------

      def token_view_dir(token)
        File.join(sub_dir, token.to_s)
      end

      def subscription_yaml(token)
        File.join(token_view_dir(token), CURRENT_VIEW)
      end

      # 为 token 建立公开视图目录并写入当前 current 的内容。
      # 无 current（从未 publish）时抛错。不依赖 symlink，Windows/Linux 均可用。
      def create_token_view(token)
        current = active_state['current']
        raise MPK::Error, 'cannot create token view: no current build' unless current && build_exists?(current)

        dir = token_view_dir(token)
        FileUtils.mkdir_p(dir)
        write_view_file(dir, current)
        true
      rescue SystemCallError
        false
      end

      # token 公开视图是否就位（mihomo.yaml 可读）。
      def token_view?(token)
        File.file?(subscription_yaml(token))
      end

      # 吊销：删除该 token 的公开视图目录（URL 立即失效），不影响其他 token。
      def remove_token_view(token)
        FileUtils.rm_rf(token_view_dir(token))
      end

      # 用给定 build 的内容原子刷新单个视图目录（tmp + rename 覆盖，路径恒在）。
      def write_view_file(view_dir, build_id)
        raise MPK::Error, "build does not exist: #{build_id}" unless build_exists?(build_id)

        FileUtils.mkdir_p(view_dir)
        target = File.join(view_dir, CURRENT_VIEW)
        tmp = File.join(view_dir, ".view-tmp-#{SecureRandom.hex(6)}")
        FileUtils.cp(build_yaml(build_id), tmp)
        atomic_rename(tmp, target) # 覆盖式原子替换：从不删除 target
        true
      ensure
        FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
      end

      # 刷新所有已存在 token 视图到给定 build 的内容（逐个原子覆盖）。
      def refresh_public_views(build_id)
        return unless File.directory?(sub_dir)

        Dir.children(sub_dir).each do |token|
          next if token.start_with?('.')

          dir = File.join(sub_dir, token)
          next unless File.directory?(dir)

          write_view_file(dir, build_id)
        end
        true
      end

      # 本地解析：给定完整 token 返回其视图对应内容来源（当前 current build 的 YAML）。
      def subscription_source_path(token)
        return nil unless token_view?(token)

        current = active_state['current']
        return nil unless current && build_exists?(current)

        build_yaml(current)
      end

      private

      # 校验一个目录是否构成可被引用的 immutable build。此校验同时用于
      # staging 落盘前的完整性确认与 builds/ 中残留目录的过滤。
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

      # active-state.json 原子替换（tmp + rename）。
      def write_active(payload)
        tmp = File.join(@root, ".active-state.json.tmp-#{SecureRandom.hex(6)}")
        File.write(tmp, JSON.pretty_generate(payload))
        atomic_rename(tmp, active_file)
      ensure
        FileUtils.rm_rf(tmp) if tmp && File.exist?(tmp)
      end

      # 自愈：把每个已存在 token 视图刷新为当前 current 的内容。
      # 覆盖“active 已切但某视图未跟上（崩溃/中断）”的滞后窗口。
      def reconcile_public_views!
        current = active_state['current']
        return unless current && build_exists?(current)
        return unless File.directory?(sub_dir)

        Dir.children(sub_dir).each do |token|
          next if token.start_with?('.')

          dir = File.join(sub_dir, token)
          next unless File.directory?(dir)

          target = File.join(dir, CURRENT_VIEW)
          next if File.file?(target) && File.binread(target) == File.binread(build_yaml(current))

          write_view_file(dir, current)
        end
      end

      # 原子 rename 包装：便于故障注入测试；生产同 File.rename。
      def atomic_rename(source, target)
        File.rename(source, target)
      end

      # View refresh 在 active 切换后失败时的回退。active 文件先原子恢复；随后
      # 最佳努力将已更新的 token 视图恢复为原 current。恢复本身再次失败也不会
      # 造成 404：目标文件始终由原子 rename 覆盖，保留的是 old/new 完整内容。
      def restore_after_view_refresh_failure(original)
        write_active(original)
        old_current = original['current']
        refresh_public_views(old_current) if old_current && build_exists?(old_current)
      rescue StandardError
        # 保留触发该回退的原始异常；下一次 init! 会继续 reconcile 视图。
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
