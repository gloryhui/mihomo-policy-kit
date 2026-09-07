# frozen_string_literal: true

require 'yaml'
require 'digest'
require 'open3'
require_relative '../overlay'
require_relative '../build_helpers'

module MPK
  module Publisher
    # 发布前的最小安全校验（复用 BuildHelpers / Overlay 的校验能力，不复制 validator）。
    #
    # 保证：
    # - 文件存在且非空
    # - YAML 可解析
    # - proxies > 0 或存在 proxy-providers
    # - proxy-groups / rules 满足当前项目校验要求
    # - 本机存在 mihomo 时执行 `mihomo -t`
    class Validator
      attr_reader :config

      def initialize(config: nil)
        @config = config
      end

      # 返回统计 Hash；校验失败抛 MPK::Error。
      def validate(path)
        raise MPK::Error, "publish artifact not found: #{path}" unless File.file?(path)
        raise MPK::Error, "publish artifact is empty: #{path}" if File.zero?(path)

        document = MPK::YAMLUtil.load_file(path)
        raise MPK::Error, 'publish artifact root must be a mapping' unless document.is_a?(Hash)

        proxies = Array(document['proxies'])
        proxy_providers = document['proxy-providers']
        groups = Array(document['proxy-groups'])
        rules = Array(document['rules'])

        provider_count = proxy_providers.is_a?(Hash) ? proxy_providers.length : 0
        if proxies.empty? && provider_count.zero?
          raise MPK::Error, 'publish artifact has no proxies or proxy-providers'
        end

        # 复用 Overlay 校验逻辑（require_proxy_groups / require_rules / require_targets）。
        if (overlay_config = config)
          overlay = MPK::Overlay.new(config: overlay_config, group_map: {})
          overlay.validate!(document, source_proxy_count: nil)
        else
          raise MPK::Error, 'publish artifact has no proxy-groups' if groups.empty?
          raise MPK::Error, 'publish artifact has no rules' if rules.empty?
        end

        stats = {
          proxies: proxies.length,
          proxy_providers: provider_count,
          proxy_groups: groups.length,
          rules: rules.length
        }

        if (mihomo = BuildHelpers.command_path('mihomo'))
          stdout, stderr, status = Open3.capture3(mihomo, '-t', '-f', path)
          $stdout.write(stdout) unless stdout.empty?
          $stderr.write(stderr) unless stderr.empty?
          raise MPK::Error, "mihomo config test failed (#{status.exitstatus})" unless status.success?

          stats[:mihomo_tested] = true
        else
          stats[:mihomo_tested] = false
        end

        stats[:sha256] = Digest::SHA256.file(path).hexdigest
        stats
      end
    end
  end
end
