# frozen_string_literal: true

require 'securerandom'
require 'digest'
require 'json'
require 'time'
require 'fileutils'

module MPK
  module Publisher
    # 订阅 Token 管理。
    #
    # - Token 使用 SecureRandom（CSPRNG）生成，至少 256 bit 随机熵，URL-safe
    # - 不以可预测自增 ID 作为 token
    # - token name 仅用于本地管理，不进入公开 URL
    # - token-state 目录仅存 name / fingerprint / created_at / active，
    #   完整 token 只出现在 token create 的一次性输出中
    class TokenStore
      TOKEN_BYTES = 32 # 256 bit
      STATE_DIR = 'token-state'

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root.to_s)
      end

      def state_dir
        File.join(@root, STATE_DIR)
      end

      def create(name)
        raise MPK::Error, 'token name must not be empty' if name.to_s.strip.empty?

        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        fingerprint = self.class.fingerprint(token)
        record = {
          'name' => name.to_s.strip,
          'fingerprint' => fingerprint,
          'created_at' => Time.now.utc.iso8601,
          'active' => true
        }

        FileUtils.mkdir_p(state_dir)
        raise MPK::Error, "token name already exists: #{name}" if name_exists?(record['name'])

        path = state_path(fingerprint)
        write_json(path, record)
        # 返回 {token, name, fingerprint, url}；token 仅此一次完整输出
        { token: token, name: record['name'], fingerprint: fingerprint, created_at: record['created_at'] }
      end

      def list
        records = Dir.glob(File.join(state_dir, '*.json')).filter_map do |path|
          record = load_json(path)
          next if record.nil?

          {
            'name' => record['name'],
            'fingerprint' => record['fingerprint'],
            'created_at' => record['created_at'],
            'active' => record['active'] != false
          }
        end
        records.sort_by { |r| [r['active'] ? 0 : 1, r['name']] }
      end

      # 按 name 精确吊销；不影响其他 token。
      def revoke(name)
        records = Dir.glob(File.join(state_dir, '*.json')).filter_map do |path|
          record = load_json(path)
          record && [path, record]
        end

        found = records.find { |_path, record| record['name'] == name.to_s.strip }
        raise MPK::Error, "token not found: #{name}" if found.nil?

        path, record = found
        record['active'] = false
        write_json(path, record)
        record['fingerprint']
      end

      # 给定完整 token 返回对应记录；token 无效或已吊销返回 nil。
      def find_active(token)
        fingerprint = self.class.fingerprint(token)
        record = load_json(state_path(fingerprint))
        return nil if record.nil? || record['active'] == false

        record
      end

      # 给定 name 返回完整 token 记录（含 token 字段）；无则 nil。
      # 仅内部用于一次性展示（token create 后无法再次取得完整 token）。
      def find_by_name(name)
        records = Dir.glob(File.join(state_dir, '*.json')).filter_map do |path|
          record = load_json(path)
          record && [path, record]
        end
        found = records.find { |_path, record| record['name'] == name.to_s.strip }
        found && found[1]
      end

      # 删除 token 记录（例如 view 创建失败时回滚孤儿记录）。
      def delete(fingerprint)
        path = state_path(fingerprint)
        File.delete(path) if File.file?(path)
      end

      # SHA256(token) 前 16 hex 作为 fingerprint；同时用于 token-state 文件名，
      # 避免把完整 token 写进文件系统路径 / 日志。
      def self.fingerprint(token)
        Digest::SHA256.hexdigest(token.to_s)[0, 16]
      end

      # 展示用掩码：保留前 4 与后 4，其余用 '*' 代替。
      def self.mask(token)
        raw = token.to_s
        return '***' if raw.length <= 8

        "#{raw[0, 4]}#{'*' * (raw.length - 8)}#{raw[-4, 4]}"
      end

      private

      def name_exists?(name)
        list.any? { |record| record['name'] == name }
      end

      def state_path(fingerprint)
        File.join(state_dir, "#{fingerprint}.json")
      end

      def write_json(path, object)
        tmp = "#{path}.tmp-#{SecureRandom.hex(4)}"
        File.write(tmp, JSON.pretty_generate(object))
        FileUtils.mv(tmp, path)
      end

      def load_json(path)
        return nil unless File.file?(path)

        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue JSON::ParserError
        nil
      end
    end
  end
end
