# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/services/build_pipeline'

class ThreeSourceIntegrationTest < Minitest::Test
  P = MPK::PersonalPolicy

  def setup
    @dir = Dir.mktmpdir('mpk-policy-integration-')
    @config = BuildHelpers.load_config(File.join(BuildHelpers::ROOT_DIR, 'config/config.example.yaml'))
    @config['custom_rules'] = { 'files' => [] }
    @core = File.join(@dir, 'mihomo-fixture')
    File.write(@core, "#!/bin/sh\nexit 0\n")
    File.chmod(0o700, @core)
    @config['policy_runtime'] = { 'mihomo' => @core }
    @provider = File.join(@dir, 'normal-fixture.sh')
    File.write(@provider, <<~SH)
      #!/bin/bash
      VERSION_TAG="test-oc-normal"
      ruby -ryaml -e '
        x=YAML.load_file(ARGV[0]); names=x.fetch("proxies").map{|p| p.fetch("name")}
        x["proxy-groups"]=[
          {"name"=>"🤖 AI 服务","type"=>"select","proxies"=>["🌍 全球节点"]},
          {"name"=>"🌍 全球节点","type"=>"select","include-all-proxies"=>true},
          {"name"=>"🇺🇸 美国节点","type"=>"select","proxies"=>names},
          {"name"=>"🚫 受限网站","type"=>"select","proxies"=>["🌍 全球节点"]}]
        x["rules"]=["DOMAIN-SUFFIX,other-ai.invalid,🤖 AI 服务","MATCH,🌍 全球节点"]
        File.write(ARGV[0],YAML.dump(x))
      ' "$1"
    SH
    @config['provider_options']['smart_config_kit']['local_script'] = @provider
    @config['policy_preset'] = 'three-source-ai'
    @output = File.join(@dir, 'result.yaml')
    @config['output'] = { 'mihomo' => @output }
    @pipeline = MPK::Services::BuildPipeline.new(log: proc { |_| })
    @port = 10000
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def node(name)
    @port += 1
    { 'name' => name, 'type' => 'trojan', 'server' => 'example.invalid', 'port' => @port,
      'password' => 'FAKE_PRIVATE_NODE', 'client-fingerprint' => 'chrome' }
  end

  def documents
    {
      'ssone' => ['日本-2x', '日本-3x', '美国-10X'],
      'tnt' => [P::TNT_AI.first, '[Lv4·3.0x] 日本1|IPLC专线|AI加速'],
      'zodaccyes' => [P::ZOD_AI.first, P::ZOD_AI.find { |n| n.include?('香港') }, 'PRO | 新加坡IPLC VL1 | 2倍']
    }.transform_values { |names| { 'proxies' => names.map { |name| node(name) } } }
  end

  def test_personal_entry_uses_shared_build_and_preserves_custom_priority_and_previous_output
    custom = File.join(@dir, 'custom.list')
    File.write(custom, "DOMAIN-SUFFIX,custom-ai.invalid,ai\n")
    @config['custom_rules'] = { 'files' => [custom] }
    @pipeline.build(@config, policy_documents: documents)
    doc = P.load_yaml(@output)
    assert_equal 4, doc['proxies'].size
    assert_equal 'DOMAIN-SUFFIX,custom-ai.invalid,其他 AI 兜底', doc['rules'].first
    assert P.validate!(doc)
    assert_equal 2, doc['proxy-groups'].find { |g| g['name'] == 'Gemini' }['proxies'].size
    assert doc['proxies'].all? { |n| n['client-fingerprint'] == 'chrome' }
    previous = File.binread(@output)
    File.write(@core, "#!/bin/sh\nexit 1\n")
    assert_raises(P::Error) { @pipeline.build(@config, policy_documents: documents) }
    assert_equal previous, File.binread(@output)
  end

  def test_personal_preset_requires_all_sources_and_normal_mihomo
    assert_raises(P::Error) { @pipeline.build(@config, policy_documents: documents.reject { |k, _| k == 'tnt' }) }
    @config['provider'] = 'acl4ssr'
    assert_raises(MPK::Error) { @pipeline.build(@config, policy_documents: documents) }
    @config['provider'] = 'smart-config-kit'
    @config['outputs'] = ['surge']
    assert_raises(MPK::Error) { @pipeline.build(@config, policy_documents: documents) }
  end

  def test_provider_cannot_silently_drop_a_subset_of_nodes
    File.write(@provider, File.read(@provider).sub('names=x.fetch', 'x["proxies"].pop; names=x.fetch'))
    assert_raises(MPK::Error) { @pipeline.build(@config, policy_documents: documents) }
    refute File.exist?(@output)
  end

  def test_private_settings_cannot_be_in_git_even_through_symlink
    repo = File.join(@dir, 'fake-repo')
    FileUtils.mkdir_p(File.join(repo, '.git'))
    path = File.join(repo, 'sources.txt')
    File.write(path, 'fake')
    assert_raises(P::Error) { P.read_settings(path) }
    link = File.join(@dir, 'link')
    File.symlink(repo, link)
    assert_raises(P::Error) { P.private_path!(File.join(link, 'new', 'sources.txt')) }
  end
end
