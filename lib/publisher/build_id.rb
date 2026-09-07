# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'time'

module MPK
  module Publisher
    # Build ID 生成与解析。
    #
    # 格式：UTC 时间 + 内容 SHA256 短摘要 + 随机后缀（避免同秒冲突）：
    #
    #   YYYYMMDDTHHMMSSZ-<sha256 前 12 hex>-<base36 4 位随机>
    #
    # - 可排序 / 可识别时间（UTC）
    # - 内容摘要帮助识别重复发布
    # - 随机后缀避免同秒冲突
    # - 不含任何 Secret
    module BuildId
      module_function

      DIGEST_LENGTH = 12
      RANDOM_LENGTH = 4
      PATTERN = /\A(\d{8}T\d{6}Z)-([0-9a-f]{#{DIGEST_LENGTH}})-([0-9a-z]{#{RANDOM_LENGTH}})\z/

      def generate(content, time: Time.now.utc)
        timestamp = time.utc.strftime('%Y%m%dT%H%M%SZ')
        digest = Digest::SHA256.hexdigest(content.to_s)[0, DIGEST_LENGTH]
        random = SecureRandom.alphanumeric(RANDOM_LENGTH).downcase
        "#{timestamp}-#{digest}-#{random}"
      end

      def valid?(id)
        id.to_s.match?(PATTERN)
      end

      # 解析出时间（Time, UTC），非法格式返回 nil。
      def timestamp(id)
        match = PATTERN.match(id.to_s)
        return nil unless match

        stamp = match[1] # YYYYMMDDTHHMMSSZ
        Time.utc(
          stamp[0, 4].to_i, stamp[4, 2].to_i, stamp[6, 2].to_i,
          stamp[9, 2].to_i, stamp[11, 2].to_i, stamp[13, 2].to_i
        )
      rescue ArgumentError
        nil
      end

      # 返回内容摘要（不含随机后缀），用于快速判断“是否同一份内容”。
      def digest(id)
        match = PATTERN.match(id.to_s)
        match && match[2]
      end
    end
  end
end
