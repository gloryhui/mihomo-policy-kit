# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/personal_policy'

class PersonalPolicyTest < Minitest::Test
  Policy = MPK::PersonalPolicy

  def proxy(name)
    { 'name' => name, 'type' => 'trojan', 'server' => 'example.invalid',
      'port' => 443, 'password' => 'fixture-only', 'client-fingerprint' => 'chrome' }
  end

  def documents
    { 'tnt' => { 'proxies' => Policy::TNT_AI.map { |n| proxy(n) } + [proxy('[Lv4·3.0x] 日本1|IPLC专线|AI加速')] },
      'zodaccyes' => { 'proxies' => Policy::ZOD_AI.map { |n| proxy(n) } + [proxy('PRO | 新加坡IPLC VL1 | 2倍')] } }
  end

  def upstream
    { 'proxies' => [proxy('[ssone] 普通-日本-2x')],
      'proxy-groups' => [
        { 'name' => Policy::OLD_AI, 'type' => 'select', 'proxies' => ['全球'] },
        { 'name' => '全球', 'type' => 'url-test', 'proxies' => ['[ssone] 普通-日本-2x'] },
        { 'name' => '🚫 受限网站', 'type' => 'select', 'proxies' => ['全球', 'DIRECT'] }
      ], 'rule-providers' => {},
      'global-client-fingerprint' => 'safari',
      'rules' => ["DOMAIN-SUFFIX,example.ai,#{Policy::OLD_AI}", 'MATCH,🚫 受限网站'] }
  end

  def compiled
    Policy.apply!(upstream, Policy.ai_nodes(documents))
  end

  def test_multiplier_boundaries_and_unicode
    ['3x', '3.0X', 'x3', '×3.0', '３倍', '倍率：3', '5x', '10X'].each do |rate|
      %w[ssone tnt].each { |s| refute Policy.eligible?("节点-#{rate}", s), rate }
    end
    ['1x', '2X', '2.99x', '[Lv4·2.0x] 美国01|AI加速', 'Lv4 普通节点'].each do |name|
      assert Policy.eligible?(name, 'ssone'), name
    end
    refute Policy.eligible?('节点-2x-10X', 'ssone')
    assert Policy.eligible?('PRO | 香港 | 1倍 高速', 'zodaccyes')
    ['PRO | 香港', 'PRO | 香港 | 0倍', 'PRO | 香港 | 1.2倍', 'PRO | 香港 | 2倍'].each do |n|
      refute Policy.eligible?(n, 'zodaccyes')
    end
    refute Policy.eligible?('剩余流量：100 GB', 'ssone')
    refute Policy.eligible?('PRO | 订阅专用节点VL | 0倍', 'zodaccyes')
  end

  def test_simple_address_file_preserves_query_equals_and_checks_all_sources
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'sources.txt')
      File.write(path, "# 注释\nssone=https://ssone.invalid/sub?token=a=b\ntnt=https://tnt.invalid/sub\nzodaccyes=https://zod.invalid/sub\n")
      result = Policy.read_settings(path)
      assert_equal 'https://ssone.invalid/sub?token=a=b', result['sources']['ssone']['url']
      assert_equal File.join(dir, 'runtime/local-policy/bin/mihomo'), result['mihomo']
      File.write(path, "ssone=https://ssone.invalid\nssone=https://duplicate.invalid\n")
      assert_raises(Policy::Error) { Policy.read_settings(path) }
      File.write(path, "ssone=https://ssone.invalid\ntnt=https://tnt.invalid\n")
      assert_raises(Policy::Error) { Policy.read_settings(path) }
    end
  end

  def test_explicit_ai_allowlist_overrides_neither_rate_nor_names
    ai = Policy.ai_nodes(documents)
    assert_equal 18, ai.size
    refute ai.any? { |p| p['name'].include?('3.0x') || p['name'].include?('2倍') }
    docs = documents
    docs['zodaccyes']['proxies'] << proxy('PRO | 美国额外节点 | 1倍')
    refute Policy.ai_nodes(docs).any? { |p| p['name'].include?('额外') }
  end

  def test_groups_are_isolated_and_gemini_has_no_hong_kong_or_generic_escape
    config = compiled
    groups = config['proxy-groups'].map { |g| [g['name'], g] }.to_h
    assert_equal 18, groups['Anthropic']['proxies'].size
    assert_equal 8, groups['Gemini']['proxies'].size
    assert_empty groups['Gemini']['proxies'].grep(/香港|DIRECT|全球/)
    assert_empty groups.keys.grep(/AI 服务/)
    assert_equal ['[ssone] 普通-日本-2x'], Policy.reachable('全球', groups)
    assert config['proxies'].all? { |n| n['client-fingerprint'] == 'chrome' }
    refute config.key?('global-client-fingerprint')
    assert_equal 'memconservative', config['geodata-loader']
  end

  def test_specific_ai_rules_precede_fallback_and_google_rules
    rules = compiled['rules']
    assert_equal ['Anthropic', 'OpenAI', 'Grok', 'Gemini', '其他 AI 兜底'], rules.first(5).map { |r| r.split(',').last }
    assert_equal 'DOMAIN-SUFFIX,example.ai,其他 AI 兜底', rules[5]
  end

  def test_fails_closed_on_transitive_ordinary_leak
    config = compiled
    config['proxy-groups'].find { |g| g['name'] == '全球' }['proxies'] << 'Anthropic'
    assert_raises(Policy::Error) { Policy.validate!(config) }
  end

  def test_duplicate_group_names_are_rejected_before_core_validation
    config = compiled
    config['proxy-groups'] << config['proxy-groups'].first.dup
    assert_raises(Policy::Error) { Policy.validate!(config) }
  end

  def test_upstream_global_include_all_is_frozen_before_ai_nodes_are_added
    config = upstream
    global = config['proxy-groups'].find { |g| g['name'] == '全球' }
    global.delete('proxies')
    global['include-all-proxies'] = true
    Policy.apply!(config, Policy.ai_nodes(documents))
    assert_equal ['[ssone] 普通-日本-2x'], global['proxies']
    refute global.key?('include-all-proxies')
    assert Policy.validate!(config)
  end

  def test_fails_closed_on_dynamic_inclusion_and_unknown_reference
    config = compiled
    config['proxy-groups'].first['include-all'] = true
    assert_raises(Policy::Error) { Policy.validate!(config) }
    config = compiled
    config['proxy-groups'].first['proxies'] << 'missing-node'
    assert_raises(Policy::Error) { Policy.validate!(config) }
  end

  def test_missing_ai_source_never_falls_back_to_direct
    docs = documents
    docs['zodaccyes']['proxies'] = [proxy('PRO | 订阅专用节点 | 0倍')]
    assert_raises(Policy::Error) { Policy.ai_nodes(docs) }
    docs = documents
    docs['tnt']['proxies'] = []
    assert_raises(Policy::Error) { Policy.ai_nodes(docs) }
  end

  def test_fetch_uses_stdin_for_secrets_and_never_prints_upstream_errors
    Dir.mktmpdir do |dir|
      curl = File.join(dir, 'curl')
      capture = File.join(dir, 'capture.json')
      File.write(curl, "#!/usr/bin/env ruby\nrequire 'json'\nFile.write(ENV.fetch('CAPTURE'), JSON.generate([ARGV, STDIN.read]))\nwarn 'SECRET_SERVER_PASSWORD'\nexit 1\n")
      File.chmod(0o700, curl)
      old_path, old_capture = ENV['PATH'], ENV['CAPTURE']
      begin
        ENV['PATH'] = dir + File::PATH_SEPARATOR + old_path
        ENV['CAPTURE'] = capture
        error = assert_raises(Policy::Error) { Policy.fetch!({ 'url' => 'https://example.invalid/private-token' }, File.join(dir, 'out')) }
        refute_includes error.message, 'SECRET'
        args, input = JSON.parse(File.read(capture))
        refute_includes args.join(' '), 'private-token'
        assert_includes args, '--retry-all-errors'
        assert_equal '2', args[args.index('--retry') + 1]
        assert_includes input, 'private-token'
      ensure
        ENV['PATH'], ENV['CAPTURE'] = old_path, old_capture
      end
    end
  end

  def test_failed_generation_retains_existing_output
    Dir.mktmpdir do |dir|
      output = File.join(dir, 'out.yaml')
      settings = File.join(dir, 'sources.json')
      File.write(output, 'previous-good-output')
      File.write(settings, '{}')
      assert_raises(Policy::Error) { Policy.build(settings, output) }
      assert_equal 'previous-good-output', File.read(output)
    end
  end

  def test_gated_refresh_uses_own_gateway_retries_and_stops_temporary_core
    Dir.mktmpdir do |dir|
      core = File.join(dir, 'fake-core')
      pid_file = File.join(dir, 'pids')
      File.write(core, <<~RUBY)
        #!#{RbConfig.ruby}
        require 'yaml'
        require 'socket'
        exit 0 if ARGV.include?('-t')
        File.open(#{pid_file.inspect}, 'a') { |f| f.puts Process.pid }
        c = YAML.load_file(ARGV[ARGV.index('-f') + 1])
        socket = TCPServer.new('127.0.0.1', c['listeners'][0]['port'])
        sleep 60
      RUBY
      File.chmod(0o700, core)
      bootstrap = { 'proxies' => [proxy('PRO | 订阅专用节点AN | 0倍'), proxy('PRO | 订阅专用节点VL | 0倍')] }
      calls = []
      full_document = documents['zodaccyes']
      fetcher = lambda do |source, path, proxy: nil|
        calls << proxy
        raise Policy::Error, 'gateway one unavailable' if calls.size == 1
        full_document
      end
      original_interface = Policy.method(:physical_interface)
      original_fetch = Policy.method(:fetch!)
      begin
        Policy.define_singleton_method(:physical_interface) { nil }
        Policy.define_singleton_method(:fetch!, fetcher)
        full = Policy.fetch_gated!({}, bootstrap, core, dir)
        assert_equal documents['zodaccyes'], full
      ensure
        Policy.define_singleton_method(:physical_interface, original_interface)
        Policy.define_singleton_method(:fetch!, original_fetch)
      end
      assert_equal 2, calls.size
      assert calls.all? { |p| p.start_with?('http://127.0.0.1:') }
      File.readlines(pid_file).each do |line|
        assert_raises(Errno::ESRCH) { Process.kill(0, line.to_i) }
      end
    end
  end

  def test_gated_refresh_rejects_hint_only_results
    Dir.mktmpdir do |dir|
      initial = { 'proxies' => [] }
      assert_raises(Policy::Error) { Policy.fetch_gated!({}, initial, '/missing/core', dir) }
    end
  end
end
