# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'build_id'
require_relative 'runtime'
require_relative 'token'
require_relative 'validator'

module MPK
  module Publisher
    # Publisher 主流程：publish / status / rollback / token。
    #
    # Publish 顺序（Issue #11 02）：
    #   source artifact
    #     -> 校验（存在、非空、YAML、proxies/provider、groups/rules、可选 mihomo -t）
    #     -> 写 metadata
    #     -> 完整 build 原子进入 builds/<build-id>
    #     -> 最后才切换 current/previous
    #
    # 失败安全（Sol Review P0）：
    #   - build 目录写入失败时清理半成品目录，不留下孤儿 build
    #   - 任何失败都不改变线上 current；promote 失败时 current/previous 与操作前完全一致
    class Publisher
      attr_reader :runtime, :tokens, :config

      def initialize(root:, config: nil, env: ENV, runtime: nil)
        @runtime = runtime || Runtime.new(root)
        @tokens = TokenStore.new(root)
        @config = config
        @env = env
      end

      def root
        runtime.root
      end

      def init!
        runtime.init!
        self
      end

      # 发布一个已经构建并校验过的 Mihomo YAML。
      # 相同内容（SHA256 相同）发布时行为明确且幂等：直接返回已存在的 build，
      # 不产生重复版本，也不改变 current（如果 current 已指向该内容）。
      def publish(artifact_path, public_base_url: nil)
        runtime.init!
        raise MPK::Error, "artifact not found: #{artifact_path}" unless File.file?(artifact_path)

        stats = Validator.new(config: config).validate(artifact_path)
        content = File.binread(artifact_path)
        sha256 = Digest::SHA256.hexdigest(content)

        # 幂等：若已存在同内容 build，直接复用它作为 current（不新建重复版本），
        # 即使该 build 不是当前 current（例如发布回 previous 的内容）。
        existing = find_build_by_sha256(sha256)
        if existing
          if runtime.current_build_id == existing
            return { build_id: existing, published: false, current: existing, previous: runtime.previous_build_id, stats: stats }
          end

          runtime.promote!(existing)
          return { build_id: existing, published: false, current: existing, previous: runtime.previous_build_id, stats: stats }
        end

        build_id = BuildId.generate(content, time: Time.now.utc)
        build_id = ensure_unique_build_id(build_id, sha256)

        metadata = {
          'build_id' => build_id,
          'published_at' => Time.now.utc.iso8601,
          'sha256' => sha256,
          'proxies' => stats[:proxies],
          'proxy_providers' => stats[:proxy_providers],
          'proxy_groups' => stats[:proxy_groups],
          'rules' => stats[:rules],
          'mihomo_tested' => stats[:mihomo_tested]
        }
        # YAML + metadata 先在 staging 写完整，再一次性原子 rename 进入 builds/：
        # 中途崩溃最多遗留 staging，builds/ 只出现完整 build。
        runtime.commit_build(build_id, content, metadata)

        # 最后才切换 current/previous（单点 active 指针）
        runtime.promote!(build_id)

        { build_id: build_id, published: true, current: build_id, previous: runtime.previous_build_id, stats: stats }
      end

      # 发布相同内容（幂等路径）：第二次 publish 同一份内容，current 不变，previous 不变。
      # 上面 publish 已处理；此方法仅为语义明确的别名。
      def publish_idempotent(artifact_path)
        publish(artifact_path)
      end

      def rollback
        runtime.init!
        current_before = runtime.current_build_id
        previous_before = runtime.previous_build_id
        raise MPK::Error, 'nothing to roll back: no previous build' unless runtime.previous_exists?

        runtime.rollback!
        { current: runtime.current_build_id, previous: runtime.previous_build_id,
          rolled_back_from: current_before, rolled_back_to: previous_before }
      end

      def status
        runtime.init!
        {
          root: runtime.root,
          current: runtime.current_build_id,
          previous: runtime.previous_build_id,
          builds: runtime.list_builds,
          tokens: tokens.list
        }
      end

      # 创建 token 并建立公开视图：public/sub/<完整 token>/mihomo.yaml（真实文件跟随 current）。
      # 完整 token 只在本方法返回值中一次性出现；token-state 是私有敏感数据，
      # 记录完整 token 用于 filesystem 视图管理（revoke 精确删除），
      # 但普通 list / status / 日志不得输出。
      def create_token(name, public_base_url: nil)
        runtime.init!
        result = tokens.create(name)
        begin
          created = runtime.create_token_view(result[:token])
        rescue MPK::Error
          # view 创建失败（例如尚无 current build）：回滚 token 记录，避免孤儿状态
          tokens.delete(result[:fingerprint])
          raise
        end
        unless created
          tokens.delete(result[:fingerprint])
          raise MPK::Error, 'token view creation failed'
        end

        url = build_sub_url(public_base_url, result[:token])
        result.merge(url: url, view_created: created)
      end

      def list_tokens
        runtime.init!
        tokens.list
      end

      # 吊销指定 name 的 token：移除其公开视图（精确到完整 token 的 URL 路径），
      # 不影响其他 token。
      def revoke_token(name)
        runtime.init!
        record = tokens.find_by_name(name)
        raise MPK::Error, 'token not found: ' + name.to_s if record.nil?

        token = record['token']
        runtime.remove_token_view(token)
        tokens.revoke(name)
        TokenStore.fingerprint(token)
      end

      # 给定完整 token 解析稳定 URL 对应的文件（跟随 current）。
      # 供 Nginx 之外的本地校验 / 测试使用。
      def resolve_subscription(token)
        record = tokens.find_active(token)
        return nil if record.nil?

        build_id = runtime.current_build_id
        return nil if build_id.nil?

        runtime.build_yaml(build_id)
      end

      private

      def ensure_unique_build_id(build_id, sha256)
        candidate = build_id
        loop do
          # 半成品 / 崩溃残留目录也不得被覆盖；为它们换一个全新 build-id，
          # 正常 publish 因此不会受污染。
          return candidate unless File.exist?(runtime.build_dir(candidate))

          candidate = BuildId.generate(sha256, time: Time.now.utc)
        end
      end

      def find_build_by_sha256(sha256)
        runtime.list_builds.find do |id|
          metadata = runtime.build_metadata(id)
          metadata && metadata['sha256'] == sha256
        end
      end


      def build_sub_url(public_base_url, token)
        base = public_base_url.to_s.sub(%r{/+\z}, '')
        raise MPK::Error, 'public base URL is required to print the subscription URL' if base.empty?

        "#{base}/sub/#{token}/mihomo.yaml"
      end
    end
  end
end
