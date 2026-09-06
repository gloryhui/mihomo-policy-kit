# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'yaml'
require 'open3'
require 'rbconfig'
require 'fileutils'
require_relative '../lib/overlay'

# Offline end-to-end build test (Issue #7-06).
# Runs the real scripts/build.rb pipeline against a self-contained source
# fixture and a fake preserving upstream. No network, no real credentials.
class OfflineE2ETest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def ruby
    RbConfig.ruby
  end

  def write_lf(path, content)
    File.binwrite(path, content.gsub("\r\n", "\n"))
  end

  def build_config(dir, dns_profile:, output:)
    {
      'version' => 1,
      'provider' => 'smart-config-kit',
      'source' => { 'file' => File.join(ROOT, 'test/providers/fixtures/source-fixture.yaml') },
      'provider_options' => {
        'smart_config_kit' => {
          'local_script' => File.join(ROOT, 'test/providers/fixtures/fake-preserving-upstream.sh'),
          'remote_url' => 'https://example.invalid/unused'
        }
      },
      'custom_rules' => {
        'files' => [File.join(dir, 'custom.list')],
        'allow_missing' => false
      },
      'groups' => { 'map_file' => File.join(dir, 'groups.yaml') },
      'patches' => {
        'remove_global_client_fingerprint' => true,
        'dns_profile' => dns_profile,
        'geodata_loader' => 'memconservative'
      },
      'validation' => {
        'min_proxy_count' => 1,
        'require_proxy_groups' => true,
        'require_rules' => true,
        'require_targets' => %w[global direct]
      },
      'output' => { 'mihomo' => output }
    }
  end

  def setup_workdir
    Dir.mktmpdir('mpk-e2e-') do |dir|
      write_lf(File.join(dir, 'custom.list'), "DOMAIN-SUFFIX,experientiallabs.ai,global\n")
      write_lf(File.join(dir, 'groups.yaml'), <<~YAML)
        ai: "🤖 AI 服务"
        global: "🌍 全球节点"
        direct: DIRECT
      YAML
      yield dir
    end
  end

  # 使用脱敏 base64 订阅 fixture（机场常见格式）验证完整链路。
  def build_config_base64(dir, dns_profile:, output:)
    cfg = build_config(dir, dns_profile: dns_profile, output: output)
    cfg['source'] = { 'file' => File.join(ROOT, 'test/providers/fixtures/source-base64-subscription.txt') }
    cfg['provider_options']['smart_config_kit']['local_script'] =
      File.join(ROOT, 'test/providers/fixtures/fake-uri-list-upstream.sh')
    cfg['validation']['require_targets'] = %w[global direct]
    cfg
  end

  def run_build(config_path)
    stdout, stderr, status = Open3.capture3(ruby, File.join(ROOT, 'scripts/build.rb'), config_path)
    [stdout, stderr, status]
  end

  # Sol Review #3：build.rb 第三参数覆盖输出路径，smoke 可保留两份明确命名产物。
  def test_output_override_keeps_two_profiles
    setup_workdir do |dir|
      config_path = File.join(dir, 'config.yaml')
      output_up = File.join(dir, 'dist', 'mihomo.yaml')
      output_cc = File.join(dir, 'dist', 'mihomo-china-compat.yaml')

      # config 默认写 upstream -> mihomo.yaml；再用第三参数覆盖 china_compat -> mihomo-china-compat.yaml
      write_lf(config_path, YAML.dump(build_config(dir, dns_profile: 'upstream', output: output_up)))
      _out, _err, status = run_build(config_path)
      assert status.success?, "first build failed"

      out2, err2, status2 = Open3.capture3(
        ruby, File.join(ROOT, 'scripts/build.rb'), config_path, 'china_compat', output_cc
      )
      assert status2.success?, "second build failed: #{out2} #{err2}"

      assert File.file?(output_up), 'upstream output missing'
      assert File.file?(output_cc), 'china_compat output missing'

      doc_up = MPK::YAMLUtil.load_file(output_up)
      doc_cc = MPK::YAMLUtil.load_file(output_cc)
      # upstream 保留原始 DNS（dns.google），china_compat 使用国内 DoH
      assert_equal ['https://dns.google/dns-query'], doc_up.dig('dns', 'nameserver')
      assert_equal ['https://223.5.5.5/dns-query', 'https://120.53.53.53/dns-query'], doc_cc.dig('dns', 'nameserver')
    end
  end

  def test_upstream_profile_e2e
    setup_workdir do |dir|
      output = File.join(dir, 'dist', 'mihomo.yaml')
      config_path = File.join(dir, 'config.yaml')
      write_lf(config_path, YAML.dump(build_config(dir, dns_profile: 'upstream', output: output)))

      stdout, stderr, status = run_build(config_path)
      assert status.success?, "build failed: #{stdout} #{stderr}"
      assert File.file?(output), 'output missing'

      doc = MPK::YAMLUtil.load_file(output)
      assert_operator Array(doc['proxies']).length, :>, 0
      refute doc.key?('global-client-fingerprint')
      assert_equal 'memconservative', doc['geodata-loader']

      # 节点级 client-fingerprint 保留
      fps = Array(doc['proxies']).filter_map { |p| p['client-fingerprint'] }
      assert_includes fps, 'chrome'
      assert_includes fps, 'safari'

      # custom rule 在最前；provider rule 紧随其后且不被 Overlay 重写
      assert_equal 'DOMAIN-SUFFIX,experientiallabs.ai,🌍 全球节点', doc['rules'].first
      assert_equal 'DOMAIN-SUFFIX,provider-tracked.example,global', doc['rules'][1]

      # upstream DNS 不被覆盖
      assert_equal true, doc.dig('dns', 'enable')
      assert_equal ['https://dns.google/dns-query'], doc.dig('dns', 'nameserver')
    end
  end

  def test_china_compat_profile_e2e
    setup_workdir do |dir|
      output = File.join(dir, 'dist', 'mihomo.yaml')
      config_path = File.join(dir, 'config.yaml')
      write_lf(config_path, YAML.dump(build_config(dir, dns_profile: 'china_compat', output: output)))

      stdout, stderr, status = run_build(config_path)
      assert status.success?, "build failed: #{stdout} #{stderr}"
      assert File.file?(output), 'output missing'

      doc = MPK::YAMLUtil.load_file(output)
      assert_equal true, doc.dig('dns', 'enable')
      assert_equal ['223.5.5.5', '119.29.29.29'], doc.dig('dns', 'default-nameserver')
      assert_equal ['https://223.5.5.5/dns-query', 'https://120.53.53.53/dns-query'], doc.dig('dns', 'nameserver')
      assert_equal false, doc.dig('dns', 'respect-rules')
      assert_equal 'memconservative', doc['geodata-loader']
      refute doc.key?('global-client-fingerprint')
    end
  end


  def test_base64_subscription_source_e2e
    setup_workdir do |dir|
      output = File.join(dir, 'dist', 'mihomo.yaml')
      config_path = File.join(dir, 'config.yaml')
      write_lf(config_path, YAML.dump(build_config_base64(dir, dns_profile: 'upstream', output: output)))

      stdout, stderr, status = run_build(config_path)
      assert status.success?, "build failed: #{stdout} #{stderr}"
      assert File.file?(output), 'output missing'
      doc = MPK::YAMLUtil.load_file(output)
      assert_operator Array(doc['proxies']).length, :>, 0
      # source 计数来自 base64 URI 解码（3 行）；最终 proxies 非空
      assert_operator Array(doc['proxies']).length, :>=, 1
      refute doc.key?('global-client-fingerprint')
      assert_equal 'memconservative', doc['geodata-loader']
    end
  end
  def test_failed_build_keeps_existing_output
    setup_workdir do |dir|
      output = File.join(dir, 'dist', 'mihomo.yaml')
      config_path = File.join(dir, 'config.yaml')

      # 先成功构建一次
      write_lf(config_path, YAML.dump(build_config(dir, dns_profile: 'upstream', output: output)))
      _out, _err, status = run_build(config_path)
      assert status.success?
      assert File.file?(output)
      first_content = File.binread(output)

      # 构造一个会失败的构建：local_script 指向不存在的 fake -> provider 失败
      bad_config = build_config(dir, dns_profile: 'upstream', output: output)
      bad_config['provider_options']['smart_config_kit']['local_script'] = File.join(dir, 'missing-upstream.sh')
      bad_config_path = File.join(dir, 'config-bad.yaml')
      write_lf(bad_config_path, YAML.dump(bad_config))

      _out, _err, bad_status = run_build(bad_config_path)
      refute bad_status.success?, 'bad build should fail'
      assert File.file?(output), 'existing output should survive'
      assert_equal first_content, File.binread(output), 'existing output should be unchanged'
    end
  end
end