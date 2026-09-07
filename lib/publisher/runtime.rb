# frozen_string_literal: true

require 'fileutils'
require 'json'
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
    #     builds/<build-id>/mihomo.yaml + metadata.json   # immutable 版本
    #     current/mihomo.yaml                            # 当前成功版本的发布视图
    #     previous/mihomo.yaml                           # 切换前的发布视图（第二次发布后存在）
    #     public/sub/<token>/ -> ../../current           # 目录 symlink（token = 完整高熵 token）
    #     token-state/<fingerprint>.json                 # token 元数据（含 token，敏感，仅私有 state）
    #
    # 原子性与失败安全（Issue #11 03 + Sol Review P0）：
    #   - build 目录一旦完整写入后 immutable；promote / rollback 只交换 current/previous
    #     视图目录，绝不修改 builds/<id> 内容。
    #   - promote! / rollback! 从不先销毁旧 previous：旧 previous 先移入唯一命名的
    #     journal 备份目录（.prev-backup-* / .rollback-backup-*），只有新状态完全
    #     就位后才删除备份。
    #   - 任一步 rename 失败都按逆序恢复（restore_after_failed_*），保证失败后
    #     current/previous 与操作前完全一致（内容与 metadata 均可用，previous 不丢失）。
    #   - 进程中途崩溃后的自愈：操作入口会先检查 journal 备份并把它们恢复到空的
    #     权威槽位（current/previous），绝不覆盖已有状态。
    #   - 正常发布期间 current 槽在两个 rename 之间可能短暂缺失（客户端 404），
    #     但绝不会指向半成品 build；失败路径保证恢复到操作前状态。
    class Runtime
      BUILDS_DIR = 'builds'
      CURRENT_DIR = 'current'
      PREVIOUS_DIR = 'previous'
      PUBLIC_DIR = 'public'
      SUB_DIR = 'sub'
      CURRENT_VIEW = 'mihomo.yaml'

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root.to_s)
      end

      def builds_dir = File.join(@root, BUILDS_DIR)
      def current_dir = File.join(@root, CURRENT_DIR)
      def previous_dir = File.join(@root, PREVIOUS_DIR)
      def public_dir = File.join(@root, PUBLIC_DIR)
      def sub_dir = File.join(public_dir, SUB_DIR)
      def current_yaml = File.join(current_dir, CURRENT_VIEW)
      def previous_yaml = File.join(previous_dir, CURRENT_VIEW)

      # 初始化运行目录（幂等）：不存在则创建空骨架；若上次 promote/rollback
      # 中途崩溃遗留 journal 备份，则先自愈恢复 current/previous 一致状态。
      def init!
        [builds_dir, public_dir, sub_dir].each { |dir| FileUtils.mkdir_p(dir) }
        recover_interrupted_state!
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

      def build_exists?(build_id)
        File.file?(build_yaml(build_id))
      end

      # 列出 builds 下所有 build-id（按字典序即时间序）。
      def list_builds
        return [] unless File.directory?(builds_dir)

        Dir.children(builds_dir).select { |id| build_exists?(id) }.sort
      end

      # 当前生效的 build-id：解析 current 目录的 metadata；无则 nil。
      def current_build_id
        metadata = read_view_metadata(current_dir)
        metadata && metadata['build_id']
      end

      def previous_build_id
        metadata = read_view_metadata(previous_dir)
        metadata && metadata['build_id']
      end

      def current_exists?
        File.file?(current_yaml)
      end

      def previous_exists?
        File.file?(previous_yaml)
      end

      # token 公开视图：public/sub/<token> -> ../../current（目录 symlink）。
      # 目录名 = 客户端 URL 中的完整高熵 token，静态 Nginx 可真实命中
      # /sub/<token>/mihomo.yaml；revoke 时删除该目录即精确吊销，不影响其他 token。
      def token_view_dir(token)
        File.join(sub_dir, token.to_s)
      end

      def subscription_yaml(token)
        File.join(token_view_dir(token), CURRENT_VIEW)
      end

      # 为 token 建立公开视图。Windows 无 symlink 权限时返回 false（由调用方处理）。
      def create_token_view(token)
        link = token_view_dir(token)
        FileUtils.rm_rf(link) if File.exist?(link)
        # public/sub/<token>/mihomo.yaml -> <root>/current/mihomo.yaml
        # symlink 目标相对 link 所在目录（public/sub）解析：../../current = <root>/current
        File.symlink(File.join('..', '..', CURRENT_DIR), link)
        true
      rescue NotImplementedError, SystemCallError
        false
      end

      # token 公开视图是否就位。
      def token_view?(token)
        path = token_view_dir(token)
        File.symlink?(path) || File.directory?(path)
      end

      # 吊销：删除该 token 的公开视图（精确到该 token 的 URL 路径）。
      def remove_token_view(token)
        FileUtils.rm_rf(token_view_dir(token))
      end

      # 把一个完整 build 提升为 current，并把旧 current 降为 previous。
      #
      # 失败安全步骤：
      #   1. 旧 previous 移入 .prev-backup-* journal（不销毁）
      #   2. current -> previous
      #   3. 新视图 -> current
      #   4. 成功后才删除 journal 备份
      # 任一步失败都逆序恢复，失败后 current/previous 与操作前完全一致。
      def promote!(build_id)
        raise MPK::Error, "build does not exist: #{build_id}" unless build_exists?(build_id)

        recover_interrupted_state!

        prepare = build_view_dir(build_id)
        backup = nil
        prev_backed_up = false
        current_demoted = false
        begin
          if File.directory?(previous_dir)
            backup = journal_dir('.prev-backup')
            atomic_rename(previous_dir, backup)
            prev_backed_up = true
          end
          if File.directory?(current_dir)
            atomic_rename(current_dir, previous_dir)
            current_demoted = true
          end
          atomic_rename(prepare, current_dir)
          prepare = nil
          backup = nil
        rescue StandardError
          restore_after_failed_promote(backup, prev_backed_up, current_demoted)
          raise
        ensure
          # prepare 只是新视图的暂存副本（builds/ 中仍有权威内容），失败时可直接清理。
          FileUtils.rm_rf(prepare) if prepare && File.exist?(prepare)
        end
        cleanup_stale_journals!
        build_id
      end

      # 回滚：current 与 previous 互换（仅切换视图目录，不修改 builds）。
      #
      # 失败安全步骤：
      #   1. previous 移入 .rollback-backup-* journal
      #   2. current -> previous
      #   3. journal -> current（完成互换）
      # 任一步失败都逆序恢复，失败后 current/previous 与操作前完全一致。
      def rollback!
        recover_interrupted_state!
        raise MPK::Error, 'nothing to roll back: no previous build' unless previous_exists?

        backup = journal_dir('.rollback-backup')
        prev_backed_up = false
        current_moved = false
        begin
          atomic_rename(previous_dir, backup)
          prev_backed_up = true
          atomic_rename(current_dir, previous_dir)
          current_moved = true
          atomic_rename(backup, current_dir)
          backup = nil
        rescue StandardError
          restore_after_failed_rollback(backup, prev_backed_up, current_moved)
          raise
        end
        cleanup_stale_journals!
        current_build_id
      end

      private

      # 构造一个完整的新 current 视图目录（真实目录：mihomo.yaml + metadata.json），
      # 之后整体 rename 就位，避免半成品视图被客户端读到。
      def build_view_dir(build_id)
        dir = journal_dir('.view')
        FileUtils.mkdir_p(dir)
        FileUtils.cp(build_yaml(build_id), File.join(dir, CURRENT_VIEW))
        write_view_metadata(dir, build_id)
        dir
      end

      # 单独抽出的 rename，便于故障注入测试（子类可在指定次数抛错）。
      def atomic_rename(source, target)
        File.rename(source, target)
      end

      # promote! 失败恢复：先恢复 current 槽（若已降级到 previous 槽），
      # 再把旧 previous 从 journal 备份移回 previous 槽。
      def restore_after_failed_promote(backup, prev_backed_up, current_demoted)
        if current_demoted && File.directory?(previous_dir) && !File.directory?(current_dir)
          atomic_rename(previous_dir, current_dir)
        end
        if prev_backed_up && backup && File.directory?(backup) && !File.directory?(previous_dir)
          atomic_rename(backup, previous_dir)
        end
      end

      # rollback! 失败恢复：语义同 promote，把两个槽恢复成操作前状态。
      def restore_after_failed_rollback(backup, prev_backed_up, current_moved)
        if current_moved && File.directory?(previous_dir) && !File.directory?(current_dir)
          atomic_rename(previous_dir, current_dir)
        end
        if prev_backed_up && backup && File.directory?(backup) && !File.directory?(previous_dir)
          atomic_rename(backup, previous_dir)
        end
      end

      # 进程在 promote/rollback 中途崩溃后的自愈（仅当权威槽位为空且存在 journal
      # 备份时恢复，绝不覆盖已有状态）。原子 rename 保证失败时源目录保持原位，
      # 因此只检查槽位是否为空即可安全判断。
      def recover_interrupted_state!
        backup = newest_journal('.rollback-backup')
        if backup
          if !File.directory?(current_dir) && File.directory?(previous_dir)
            # rollback 第 2 步后崩溃：完成互换（backup 即旧 previous -> current）
            atomic_rename(backup, current_dir)
          elsif File.directory?(current_dir) && !File.directory?(previous_dir)
            # rollback 第 1 步后崩溃：撤销（previous 从未被真正切换）
            atomic_rename(backup, previous_dir)
          elsif File.directory?(current_dir) && File.directory?(previous_dir)
            # 互换已生效但清理前崩溃：backup 已无意义，安全删除
            FileUtils.rm_rf(backup)
          end
        end
        backup = newest_journal('.prev-backup')
        if backup
          if File.directory?(current_dir) && !File.directory?(previous_dir)
            # promote 第 1 步后崩溃：撤销（旧 previous 仍有效）
            atomic_rename(backup, previous_dir)
          elsif !File.directory?(current_dir) && File.directory?(previous_dir)
            # promote 第 2 步后崩溃：恢复操作前状态（previous 槽是旧 current，backup 是旧 previous）
            atomic_rename(previous_dir, current_dir)
            atomic_rename(backup, previous_dir)
          elsif File.directory?(current_dir) && File.directory?(previous_dir)
            # promote 已完成但清理前崩溃：backup 为被取代的旧 previous，可安全删除
            FileUtils.rm_rf(backup)
          end
        end
      end

      # 成功路径收尾：清除所有过期 journal / 暂存视图目录。
      # 此时 current/previous 已一致，备份内容均为被取代的旧版本，可安全删除。
      def cleanup_stale_journals!
        ['.view-*', '.prev-backup-*', '.rollback-backup-*'].each do |pattern|
          Dir.glob(File.join(@root, pattern)).each do |path|
            FileUtils.rm_rf(path) if File.directory?(path)
          end
        end
      end

      def journal_dir(tag)
        File.join(@root, "#{tag}-#{SecureRandom.hex(6)}")
      end

      def newest_journal(tag)
        Dir.glob(File.join(@root, "#{tag}-*"))
           .select { |path| File.directory?(path) }
           .max_by { |path| File.mtime(path) }
      end

      # current/previous 目录内的 metadata.json 仅用于记录 build_id 便于解析；
      # 真正的 build metadata 在 builds/<id>/metadata.json。
      def write_view_metadata(dir, build_id)
        File.write(
          File.join(dir, 'metadata.json'),
          JSON.pretty_generate('build_id' => build_id, 'updated_at' => Time.now.utc.iso8601)
        )
      end

      def read_view_metadata(dir)
        path = File.join(dir, 'metadata.json')
        return nil unless File.file?(path)

        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue JSON::ParserError
        nil
      end
    end
  end
end
