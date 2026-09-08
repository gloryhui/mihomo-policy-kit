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
    Dir.mktmpdir do |dir|
      provider = File.join(dir, 'providers', 'requested')
      FileUtils.mkdir_p(provider)
      File.write(File.join(provider, 'runner.rb'), '')
      File.write(File.join(provider, 'groups.yaml'), "global: G\n")
      File.write(File.join(provider, 'manifest.yaml'), <<~YAML)
        id: declared-other
        input_format: mihomo-yaml
        output_format: mihomo-yaml
        runner:
          kind: ruby
          entrypoint: runner.rb
        group_map: groups.yaml
      YAML
      error = assert_raises(MPK::Error) { MPK::ManifestLoader.new(root_dir: dir).load('requested') }
      assert_includes error.message, 'provider id mismatch'
    end
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

  def test_smart_config_local_script_is_root_relative_from_any_cwd
    manifest = MPK::ManifestLoader.new(root_dir: ROOT).load('smart-config-kit')
    config = {
      'provider_options' => {
        'smart_config_kit' => {
          'local_script' => './test/providers/fixtures/fake-preserving-upstream.sh',
          'remote_url' => 'https://example.invalid/not-used'
        }
      }
    }

    # The runner may be invoked from a scheduler's arbitrary cwd.  Verify the
    # Bash environment receives the repository-root path, before Bash is run.
    runner = MPK::ProviderRunner.new(root_dir: ROOT)
    env = runner.send(:provider_env, manifest, config)
    expected = BuildHelpers.bash_path_for(File.join(ROOT, 'test/providers/fixtures/fake-preserving-upstream.sh'))
    assert_equal expected, env['MPK_PROVIDER_LOCAL']
  end
end
