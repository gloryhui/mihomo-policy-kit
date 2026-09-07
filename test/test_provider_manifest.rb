# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require_relative '../lib/provider_manifest'
require_relative '../lib/provider_runner'

class ProviderManifestTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_builtin_manifests_load
    loader = MPK::ManifestLoader.new(root_dir: ROOT)
    %w[smart-config-kit acl4ssr].each do |id|
      manifest = loader.load(id)
      assert_equal id, manifest.id
      assert_equal 'mihomo-yaml', manifest.input_format
      assert File.file?(manifest.group_map)
    end
  end

  def test_missing_manifest_field_fails_without_secret
    Dir.mktmpdir do |dir|
      provider = File.join(dir, 'providers', 'bad')
      FileUtils.mkdir_p(provider)
      File.write(File.join(provider, 'manifest.yaml'), "id: bad\n")
      error = assert_raises(MPK::Error) { MPK::ManifestLoader.new(root_dir: dir).load('bad') }
      refute_includes error.message, 'VERY_SECRET_TEST_TOKEN_123'
      assert_includes error.message, 'missing fields'
    end
  end

  def test_id_mismatch_fails
    error = assert_raises(MPK::Error) { MPK::ManifestLoader.new(root_dir: ROOT).load('does-not-exist') }
    assert_includes error.message, 'manifest not found'
  end

  def test_runner_restores_input_on_failure
    Dir.mktmpdir do |dir|
      entry = File.join(dir, 'fail.rb')
      File.write(entry, "File.write(ARGV.fetch(0), 'corrupted'); exit 2\n")
      input = File.join(dir, 'input.yaml')
      File.write(input, "proxies:\n- name: original\n")
      manifest = MPK::ProviderManifest.new(id: 'test', input_format: 'mihomo-yaml', output_format: 'mihomo-yaml',
        runner: { 'kind' => 'ruby', 'entrypoint' => entry }, group_map: '', options: {})
      assert_raises(MPK::Error) { MPK::ProviderRunner.new(root_dir: ROOT).run(manifest, input_path: input, config: {}) }
      assert_equal "proxies:\n- name: original\n", File.read(input)
    end
  end
end
