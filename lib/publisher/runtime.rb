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
    #     current/mihomo.yaml                            # 指向当前成功版本的发布视图
    #     previous/mihomo.yaml                           # 切换前的发布视图（第二次发布后存在）
    #     public/sub/<token>/ -> ../../../../current     # 目录 symlink（目标恒定）
    #     token-state/<fingerprint>.json                 # token 元数据（不含完整 token）
    #
    # 原子性约定：
    #   - build 目录一旦完整写入后 immutable，发布期间只允许删除/替换 current/previous
    #     目录，不允许修改 builds/<id> 内容
    #   - current/previous 的切换使用“临时目录 + rename”，任何失败路径都保证
    #     current 要么指向旧完整版本，要么短暂缺失（404），绝不指向半成品
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

      # 初始化运行目录（幂等）：不存在则创建空骨架。
      def init!
        [builds_dir, public_dir, sub_dir].each { |dir| FileUtils.mkdir_p(dir) }
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

      # 把一个完整 build 提升为 current，并把旧 current 降为 previous。
      #
      # 失败安全：任何一步失败都不会让 current 指向半成品 build。
      # 短暂缺失窗口（rename current -> previous 与 rename tmp -> current 之间）
      # 客户端可能收到 404，但绝不会收到半成品内容；失败时会尽力恢复。
      def promote!(build_id)
        raise MPK::Error, "build does not exist: #{build_id}" unless build_exists?(build_id)

        # 构造新的 current 视图目录（先完整写文件，再整体 rename 就位）
        tmp = File.join(@root, ".current-tmp-#{build_id}")
        FileUtils.rm_rf(tmp)
        FileUtils.mkdir_p(tmp)
        FileUtils.cp(build_yaml(build_id), File.join(tmp, CURRENT_VIEW))
        write_view_metadata(tmp, build_id)

        # 交换：current -> previous（旧 previous 只是 build 的视图，可安全重建删除）
        if File.directory?(previous_dir)
          FileUtils.rm_rf(previous_dir)
        end
        if File.directory?(current_dir)
          File.rename(current_dir, previous_dir)
        end
        begin
          File.rename(tmp, current_dir)
        rescue StandardError
          # 恢复：把刚降级的 previous 升回 current，保证旧版本可用
          File.rename(previous_dir, current_dir) if File.directory?(previous_dir) && !File.directory?(current_dir)
          raise
        end
        build_id
      end

      # 回滚：current 与 previous 互换（仅切换视图目录，不修改 builds）。
      def rollback!
        raise MPK::Error, 'nothing to roll back: no previous build' unless previous_exists?

        # current 与 previous 互换：用临时目录中转，避免中间态指向半成品。
        tmp = File.join(@root, ".rollback-tmp-#{SecureRandom.hex(4)}")
        FileUtils.rm_rf(tmp)
        File.rename(current_dir, tmp)
        File.rename(previous_dir, current_dir)
        File.rename(tmp, previous_dir)
        current_build_id
      end

      # 删除某个 token 的公开视图（吊销）。
      def remove_token_view(token_fingerprint)
        path = File.join(sub_dir, token_fingerprint)
        FileUtils.rm_rf(path) if File.exist?(path)
      end

      # 为 token 建立公开视图目录 symlink：public/sub/<fp> -> ../../../../current。
      # Windows 无权限时返回 false（由调用方决定如何处理）。
      def create_token_view(token_fingerprint)
        link = File.join(sub_dir, token_fingerprint)
        FileUtils.rm_rf(link) if File.exist?(link)
        # token 目录：<root>/public/sub/<fp>/ -> <root>/current
        # 相对路径：sub -> public（1 级）、public -> <root>（2 级），再进入 current
        File.symlink(File.join('..', '..', CURRENT_DIR), link)
        true
      rescue NotImplementedError, SystemCallError
        false
      end

      # token 公开视图是否就位。
      def token_view?(token_fingerprint)
        File.symlink?(File.join(sub_dir, token_fingerprint)) ||
          File.directory?(File.join(sub_dir, token_fingerprint))
      end

      private

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
