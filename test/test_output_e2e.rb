# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'json'
require 'open3'
require 'rbconfig'
require 'fileutils'

class OutputE2ETest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content.gsub("\r\n", "\n"))
  end

  def test_one_validated_policy_renders_all_client_artifacts
    Dir.mktmpdir('mpk-output-e2e-') do |dir|
      provider_dir = File.join(dir, 'provider')
      source = File.join(dir, 'source.yaml')
      custom = File.join(dir, 'custom.list')
      config_path = File.join(dir, 'config.yaml')
      outputs = File.join(dir, 'dist')

      write(File.join(provider_dir, 'groups.yaml'), "global: Global\nus: US\ndirect: DIRECT\n")
      write(File.join(provider_dir, 'runner.rb'), "# fixture runner intentionally preserves normalized source\n")
      write(File.join(provider_dir, 'manifest.yaml'), <<~YAML)
        id: fixture-output
        input_format: mihomo-yaml
        output_format: mihomo-yaml
        runner:
          kind: ruby
          entrypoint: runner.rb
        group_map: groups.yaml
      YAML
      write(source, <<~YAML)
        proxies:
          - name: Fake-SS
            type: ss
            server: 127.0.0.1
            port: 443
            cipher: aes-128-gcm
            password: fake-password-ss
          - name: Fake-VMess
            type: vmess
            server: 127.0.0.2
            port: 443
            uuid: 00000000-0000-0000-0000-000000000000
            cipher: auto
            alterId: 0
        proxy-groups:
          - name: US
            type: select
            proxies: [Fake-SS, DIRECT]
          - name: Global
            type: select
            proxies: [US, Fake-VMess, DIRECT]
          - name: Final
            type: select
            proxies: [Global, DIRECT]
        rules:
          - DOMAIN-SUFFIX,provider.example.invalid,Global
          - MATCH,Final
      YAML
      write(custom, "DOMAIN-SUFFIX,custom.example.invalid,global\n")
      config = {
        'version' => 1,
        'provider' => 'fixture-output',
        'provider_manifest' => File.join(provider_dir, 'manifest.yaml'),
        'source' => { 'file' => source },
        'custom_rules' => { 'files' => [custom], 'allow_missing' => false },
        'patches' => { 'remove_global_client_fingerprint' => true, 'dns_profile' => 'upstream', 'geodata_loader' => 'memconservative' },
        'validation' => { 'min_proxy_count' => 1, 'require_proxy_groups' => true, 'require_rules' => true, 'require_targets' => %w[global us direct] },
        'outputs' => %w[mihomo stash loon surge sing-box],
        'output' => {
          'mihomo' => File.join(outputs, 'mihomo.yaml'),
          'stash' => File.join(outputs, 'stash.yaml'),
          'loon' => File.join(outputs, 'loon.conf'),
          'surge' => File.join(outputs, 'surge.conf'),
          'sing-box' => File.join(outputs, 'sing-box.json')
        }
      }
      write(config_path, YAML.dump(config))

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, 'scripts/build.rb'), config_path)
      assert status.success?, "multi-output build failed: #{stdout} #{stderr}"
      %w[mihomo.yaml stash.yaml loon.conf surge.conf sing-box.json].each { |name| assert File.file?(File.join(outputs, name)), "missing #{name}" }

      assert_equal 'DOMAIN-SUFFIX,custom.example.invalid,Global', YAML.safe_load(File.read(File.join(outputs, 'stash.yaml')), aliases: true)['rules'].first
      assert_includes File.read(File.join(outputs, 'loon.conf')), 'FINAL,Final'
      assert_includes File.read(File.join(outputs, 'surge.conf')), 'FINAL,Final'
      sing_box = JSON.parse(File.read(File.join(outputs, 'sing-box.json')))
      assert_equal 'Final', sing_box.dig('route', 'final')
    end
  end
end
