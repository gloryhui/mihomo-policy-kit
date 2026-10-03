# frozen_string_literal: true

require 'openssl'
require 'base64'
require_relative '../overlay'

module MPK
  module Services
    class Failure < MPK::Error
      attr_reader :code, :status
      def initialize(code, message, status = 422)
        @code, @status = code, status
        super(message)
      end
    end

    class Crypto
      def initialize(key = ENV['MPK_MASTER_KEY'])
        @raw_key = key.to_s
      end

      def encrypt(value)
        cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
        cipher.key = key
        iv = cipher.random_iv
        cipher.auth_data = 'mpk-v0.5'
        ciphertext = cipher.update(value.to_s) + cipher.final
        { ciphertext: Base64.strict_encode64(ciphertext), iv: Base64.strict_encode64(iv),
          tag: Base64.strict_encode64(cipher.auth_tag) }
      end

      def decrypt(values)
        cipher = OpenSSL::Cipher.new('aes-256-gcm').decrypt
        cipher.key = key
        cipher.iv = Base64.strict_decode64(values.fetch(:iv))
        cipher.auth_tag = Base64.strict_decode64(values.fetch(:tag))
        cipher.auth_data = 'mpk-v0.5'
        cipher.update(Base64.strict_decode64(values.fetch(:ciphertext))) + cipher.final
      rescue OpenSSL::Cipher::CipherError, ArgumentError, KeyError
        raise Failure.new('decryption_failed', 'Secret cannot be decrypted; check the master key.')
      end

      private

      def key
        raise Failure.new('master_key_missing', 'MPK_MASTER_KEY is required to store or read Secrets.') if @raw_key.empty?
        decoded = @raw_key.match?(/\A[0-9a-fA-F]{64}\z/) ? [@raw_key].pack('H*') : Base64.strict_decode64(@raw_key)
        raise ArgumentError unless decoded.bytesize == 32
        decoded
      rescue ArgumentError
        raise Failure.new('master_key_invalid', 'MPK_MASTER_KEY must encode exactly 32 bytes (hex or base64).')
      end
    end
  end
end
