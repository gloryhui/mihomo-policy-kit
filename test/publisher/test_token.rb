# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/token'

class TokenStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('mpk-token-')
    @store = MPK::Publisher::TokenStore.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def test_create_generates_high_entropy_urlsafe_token
    result = @store.create('phone')
    assert result[:token].length >= 32
    assert result[:token].match?(%r{\A[A-Za-z0-9_-]+\z}), 'token should be URL-safe'
    assert_equal 'phone', result[:name]
    assert_equal MPK::Publisher::TokenStore.fingerprint(result[:token]), result[:fingerprint]
  end

  def test_create_tokens_are_unique
    a = @store.create('a')
    b = @store.create('b')
    refute_equal a[:token], b[:token]
  end

  def test_list_shows_name_fingerprint_not_full_token
    created = @store.create('phone')
    list = @store.list
    assert_equal 1, list.length
    assert_equal 'phone', list[0]['name']
    assert_equal created[:fingerprint], list[0]['fingerprint']
    refute_includes list[0].keys, 'token'
  end

  def test_revoke_only_affects_target
    phone = @store.create('phone')
    laptop = @store.create('laptop')
    @store.revoke('phone')

    assert_nil @store.find_active(phone[:token])
    refute_nil @store.find_active(laptop[:token])

    list = @store.list
    phone_rec = list.find { |r| r['name'] == 'phone' }
    laptop_rec = list.find { |r| r['name'] == 'laptop' }
    assert_equal false, phone_rec['active']
    assert_equal true, laptop_rec['active']
  end

  def test_revoke_missing_raises
    assert_raises(MPK::Error) { @store.revoke('nope') }
  end

  def test_find_active_rejects_unknown_and_revoked
    result = @store.create('phone')
    assert_nil @store.find_active('not-a-real-token')
    @store.revoke('phone')
    assert_nil @store.find_active(result[:token])
  end

  def test_mask_hides_middle
    assert_equal 'abcd********mnop', MPK::Publisher::TokenStore.mask('abcdefghijklmnop')
    assert_equal '***', MPK::Publisher::TokenStore.mask('short')
  end

  def test_duplicate_name_rejected
    @store.create('phone')
    assert_raises(MPK::Error) { @store.create('phone') }
  end

  def test_empty_name_rejected
    assert_raises(MPK::Error) { @store.create('  ') }
  end
end
