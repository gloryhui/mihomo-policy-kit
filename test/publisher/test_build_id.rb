# frozen_string_literal: true

require 'minitest/autorun'
require 'time'
require_relative '../../lib/overlay'
require_relative '../../lib/publisher/build_id'

class BuildIdTest < Minitest::Test
  def test_generate_produces_sortable_timestamped_id
    id = MPK::Publisher::BuildId.generate('content-a')
    assert_match(/\A\d{8}T\d{6}Z-[0-9a-f]{12}-[0-9a-z]{4}\z/, id)
    assert MPK::Publisher::BuildId.valid?(id)
  end

  def test_generate_uses_utc_time
    time = Time.utc(2026, 9, 7, 1, 2, 3)
    id = MPK::Publisher::BuildId.generate('content', time: time)
    assert id.start_with?('20260907T010203Z-')
    assert_equal time, MPK::Publisher::BuildId.timestamp(id)
  end

  def test_generate_differs_for_same_content_within_same_second
    ids = Array.new(5) { MPK::Publisher::BuildId.generate('same-content') }
    assert_equal 5, ids.uniq.length, 'random suffix should avoid same-second collision'
  end

  def test_digest_is_content_based
    a = MPK::Publisher::BuildId.generate('abc')
    b = MPK::Publisher::BuildId.generate('abc')
    c = MPK::Publisher::BuildId.generate('def')
    assert_equal MPK::Publisher::BuildId.digest(a), MPK::Publisher::BuildId.digest(b)
    refute_equal MPK::Publisher::BuildId.digest(a), MPK::Publisher::BuildId.digest(c)
  end

  def test_valid_rejects_garbage
    refute MPK::Publisher::BuildId.valid?('')
    refute MPK::Publisher::BuildId.valid?('not-a-build-id')
    refute MPK::Publisher::BuildId.valid?('20260907T010203Z-nothex-r4nd')
    refute MPK::Publisher::BuildId.valid?('20260907T010203Z-1234567890ab-R4ND')
  end

  def test_timestamp_returns_nil_for_invalid
    assert_nil MPK::Publisher::BuildId.timestamp('garbage')
  end
end
