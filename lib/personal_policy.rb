# frozen_string_literal: true

require 'yaml'
require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'socket'
require 'timeout'
require 'uri'
require 'rbconfig'

module MPK
  # Private multi-source builds: no client APIs, client files, or client overrides.
  module PersonalPolicy
    class Error < StandardError; end
    ROOT = File.expand_path('..', __dir__)
    GROUPS = { 'anthropic' => 'Anthropic', 'openai' => 'OpenAI',
               'xai' => 'Grok', 'google-gemini' => 'Gemini',
               'category-ai-!cn' => '其他 AI 兜底' }.freeze
    OLD_AI = '🤖 AI 服务'
    INFO = /剩余|剩餘|到期|重置|官网|官網|导航|導航|订阅|訂閱|流量|套餐|试用|試用|免费|免費|懒人节点|只看到/
    RATE = /(?:^|[^A-Za-z0-9.])(?:([0-9]+(?:\.[0-9]+)?)\s*[xX×倍]|[xX×]\s*([0-9]+(?:\.[0-9]+)?)|倍率\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?))(?=$|[^A-Za-z0-9.])/
    TNT_AI = (1..3).map { |i| "[Lv4·2.0x] 美国0#{i}|AI加速" }.freeze
    ZOD_AI = [
      'PRO | 新加坡BGP VL01 | 1倍', 'PRO | 新加坡BGP VL02 | 1倍',
      'PRO | 日本BGP VL01 | 1倍', 'PRO | 美国洛杉矶 VL1 | 1倍',
      'PRO | 美国科罗纳 VL2 | 1倍',
      *(1..6).map { |i| "PRO | 香港BGP VL0#{i} | 1倍 高速" },
      *(1..2).map { |i| "PRO | 香港HGC VL0#{i} | 1倍 家宽" },
      *(1..2).map { |i| "PRO | 香港HKBN VL0#{i} | 1倍 家宽" }
    ].freeze
    BUILTINS = %w[DIRECT REJECT REJECT-DROP PASS COMPATIBLE].freeze

    module_function

    def rates(name)
      name.to_s.unicode_normalize(:nfkc).scan(RATE).map { |m| m.compact.first.to_f }
    end

    def eligible?(name, source)
      return false if name.to_s.match?(INFO)
      values = rates(name)
      source == 'zodaccyes' ? !values.empty? && values.all? { |v| v == 1 } : values.none? { |v| v >= 3 }
    end

    def nodes(document, source)
      raise Error, "#{source}: expected an inline Mihomo YAML subscription" unless document.is_a?(Hash) && document['proxies'].is_a?(Array)
      document['proxies'].select do |p|
        p.is_a?(Hash) && p['name'].is_a?(String) && eligible?(p['name'], source) &&
          !%w[direct reject].include?(p['type'].to_s.downcase)
      end.map { |p| p.merge('name' => "[#{source}] #{p['name']}") }
    end

    def ai_nodes(documents)
      tnt = nodes(documents.fetch('tnt'), 'tnt').select { |n| TNT_AI.include?(n['name'].sub('[tnt] ', '')) }
      zod = nodes(documents.fetch('zodaccyes'), 'zodaccyes').select { |n| ZOD_AI.include?(n['name'].sub('[zodaccyes] ', '')) }
      raise Error, 'TNT AI allowlist is empty; refusing an incomplete build' if tnt.empty?
      raise Error, 'zodaccyes AI allowlist is empty; refusing an incomplete build' if zod.empty?
      tnt + zod
    end

    def prepare(documents)
      raise Error, 'three-source policy requires exactly ssone, tnt and zodaccyes' unless documents.is_a?(Hash) && documents.keys.sort == %w[ssone tnt zodaccyes]
      ordinary = %w[ssone tnt].flat_map do |role|
        retained = nodes(documents.fetch(role), role)
        raise Error, "#{role}: no eligible ordinary nodes" if retained.empty?
        retained
      end
      [{ 'proxies' => ordinary }, ai_nodes(documents)]
    end

    def apply!(config, ai)
      groups = config.fetch('proxy-groups')
      raise Error, 'upstream AI group missing' unless groups.any? { |g| g['name'] == OLD_AI }
      groups.reject! { |g| g['name'] == OLD_AI }
      # The Normal provider's global group uses include-all-proxies. Freeze its
      # ordinary membership BEFORE adding AI-only nodes to the document.
      groups.each do |g|
        next unless g['include-all-proxies'] || g['include-all']
        raise Error, 'unsupported dynamic upstream group' if g['use'] || g['include-all-providers'] ||
          g['filter'] || g['exclude-filter'] || g['exclude-type']
        g['proxies'] = (Array(g['proxies']) + config.fetch('proxies').map { |p| p['name'] }).uniq
        g.delete('include-all-proxies')
        g.delete('include-all')
      end
      # Do not expose AI-only exits indirectly through any ordinary selector.
      groups.each do |g|
        g['proxies'] = Array(g['proxies']).reject { |n| n == OLD_AI } if g.key?('proxies')
        raise Error, 'empty upstream group after isolation' if g['proxies'] == []
      end
      existing = config.fetch('proxies').map { |n| n['name'] }
      config['proxies'].concat(ai.reject { |n| existing.include?(n['name']) })
      ai_groups = GROUPS.each_value.map do |name|
        members = ai.map { |n| n['name'] }
        members = members.reject { |n| n.match?(/香港|Hong\s*Kong|🇭🇰|\bHK\b/i) } if name == 'Gemini'
        raise Error, 'empty AI group' if members.empty?
        { 'name' => name, 'type' => 'select', 'proxies' => members }
      end
      config['proxy-groups'] = ai_groups + groups
      config['rule-providers'] ||= {}
      priority = GROUPS.map do |category, name|
        id = "mpk-ai-#{category}"
        config['rule-providers'][id] = {
          'type' => 'http', 'behavior' => 'domain', 'format' => 'text',
          'url' => "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/#{category}.list",
          'path' => "./ruleset/mpk/#{category}.list", 'interval' => 86400,
          'proxy' => '🚫 受限网站'
        }
        "RULE-SET,#{id},#{name}"
      end
      config['rules'] = priority + config.fetch('rules').map { |r| r.gsub(OLD_AI, GROUPS.fetch('category-ai-!cn')) }
      config.delete('global-client-fingerprint')
      config['geodata-loader'] = 'memconservative'
      config['mode'] = 'rule'
      config['mixed-port'] = 7890
      config['allow-lan'] = false
      config['bind-address'] = '127.0.0.1'
      config['dns']['listen'] = '127.0.0.1:7874' if config['dns'].is_a?(Hash)
      validate!(config)
      config
    end

    def reachable(name, groups, seen = [])
      raise Error, 'cyclic policy group' if seen.include?(name)
      group = groups[name]
      return [name] unless group
      raise Error, 'dynamic node inclusion would bypass isolation' if group['use'] || group['include-all'] || group['include-all-proxies'] || group['include-all-providers']
      Array(group['proxies']).flat_map { |n| reachable(n, groups, seen + [name]) }.uniq
    end

    def validate!(config)
      names = config.fetch('proxies').map { |n| n.fetch('name') }
      groups = config.fetch('proxy-groups').map { |g| [g.fetch('name'), g] }.to_h
      raise Error, 'duplicate node/group names' unless (names + groups.keys).uniq.size == names.size + Array(config['proxy-groups']).size
      config['proxies'].each do |n|
        source = n['name'][/^\[([^\]]+)\]/, 1]
        raise Error, 'unexpected source or forbidden multiplier' unless %w[ssone tnt zodaccyes].include?(source) && eligible?(n['name'], source)
        raise Error, 'cross-node dialer reference unsupported' if n['dialer-proxy']
      end
      groups.each do |name, g|
        leaves = reachable(name, groups)
        raise Error, 'dangling policy reference' unless (leaves - names - BUILTINS).empty?
        if GROUPS.values.include?(name)
          allowed = TNT_AI.map { |n| "[tnt] #{n}" } + ZOD_AI.map { |n| "[zodaccyes] #{n}" }
          raise Error, 'AI allowlist bypass' unless (leaves - allowed).empty?
          raise Error, 'Hong Kong in Gemini' if name == 'Gemini' && leaves.any? { |n| n.include?('香港') }
        elsif leaves.any? { |n| n.start_with?('[zodaccyes]') }
          raise Error, 'zodaccyes leaked into an ordinary group'
        end
      end
      raise Error, 'missing rules' if Array(config['rules']).empty?
      true
    end

    # Subprocess output stays private: upstream errors can contain node secrets.
    def run!(*args, input: nil, env: {}, seconds: 90, label: 'external command')
      out, err, status = Timeout.timeout(seconds) { Open3.capture3(env, *args, stdin_data: input.to_s) }
      raise Error, "#{label} failed (exit #{status.exitstatus}; private details suppressed)" unless status.success?
      out
    rescue Timeout::Error
      raise Error, "#{label} timed out"
    end

    def load_yaml(path)
      YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: true)
    rescue StandardError
      raise Error, 'cannot parse private subscription YAML'
    end

    def write_private(path, text)
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(text) }
      File.chmod(0o600, path)
    end

    def curl_quote(text)
      raise Error, 'invalid source metadata' if text.to_s.match?(/[\r\n\x00]/)
      '"' + text.to_s.gsub('\\') { '\\\\' }.gsub('"', '\\"') + '"'
    end

    def fetch!(source, path, proxy: nil)
      uri = URI.parse(source.fetch('url'))
      raise Error, 'source must use HTTPS' unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo
      options = ["url = #{curl_quote(uri.to_s)}", "user-agent = #{curl_quote(source['userAgent'] || 'clash.meta')}"]
      options << "header = #{curl_quote('Authorization: ' + source['authToken'])}" if source['authToken']
      args = ['curl', '--silent', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
              '--connect-timeout', '8', '--max-time', '40', '--max-filesize', '20971520',
              '--retry', '2', '--retry-all-errors', '--retry-delay', '2', '--retry-max-time', '60',
              '--proxy', proxy.to_s, '--noproxy', proxy ? '' : '*', '--config', '-', '--output', path]
      if !proxy && (interface = physical_interface)
        args += ['--interface', interface]
      end
      run!(*args, input: options.join("\n") + "\n", seconds: 110, label: 'subscription download')
      File.chmod(0o600, path)
      load_yaml(path)
    rescue Error
      raise
    rescue StandardError
      raise Error, 'subscription download failed'
    end

    def physical_interface
      # Use normal OS routing by default. Forcing a macOS interface can make
      # otherwise reachable subscriptions fail while a system TUN is active.
      value = ENV['MPK_OUTBOUND_INTERFACE'].to_s
      value.empty? ? nil : value
    end

    def fetch_gated!(source, initial, core, work)
      gateways = Array(initial['proxies']).select { |p| p['name'].to_s.include?('订阅专用节点') }
      raise Error, 'zodaccyes dedicated subscription gateways missing' if gateways.empty?
      gateways.each_with_index do |gateway, i|
        listener = TCPServer.new('127.0.0.1', 0)
        port = listener.addr[1]
        listener.close
        config = { 'allow-lan' => false, 'mode' => 'rule', 'log-level' => 'error', 'ipv6' => false,
                   'tun' => { 'enable' => false }, 'proxies' => [gateway],
                   'dns' => { 'enable' => true, 'enhanced-mode' => 'redir-host',
                              'nameserver' => ['223.5.5.5', '119.29.29.29'],
                              'proxy-server-nameserver' => ['223.5.5.5', '119.29.29.29'] },
                   'listeners' => [{ 'name' => 'subscription', 'type' => 'http', 'listen' => '127.0.0.1',
                                     'port' => port, 'proxy' => gateway.fetch('name') }],
                   'rules' => ['MATCH,DIRECT'], 'geodata-loader' => 'memconservative' }
        interface = physical_interface
        config['interface-name'] = interface if interface
        path = File.join(work, "gateway-#{i}.yaml")
        write_private(path, YAML.dump(config))
        pid = nil
        begin
          run!(core, '-t', '-d', work, '-f', path, seconds: 20)
          File.open(File.join(work, 'gateway-private.log'), 'w', 0o600) do |log|
            pid = Process.spawn(core, '-d', work, '-f', path, out: log, err: log)
          end
          Timeout.timeout(10) do
            loop do
              begin
                TCPSocket.new('127.0.0.1', port).close
                break
              rescue SystemCallError
                sleep 0.1
              end
            end
          end
          full = fetch!(source, File.join(work, 'zod-full.yaml'), proxy: "http://127.0.0.1:#{port}")
          return full if nodes(full, 'zodaccyes').any? { |p| ZOD_AI.include?(p['name'].sub('[zodaccyes] ', '')) }
        rescue Error, Timeout::Error
          # Try the other dedicated gateway, never accept the hint-only response.
        ensure
          if pid
            begin
              Process.kill('TERM', pid)
              Timeout.timeout(5) { Process.wait(pid) }
            rescue Timeout::Error
              Process.kill('KILL', pid)
              Process.wait(pid)
            rescue Errno::ESRCH, Errno::ECHILD
              nil
            end
          end
        end
      end
      raise Error, 'zodaccyes full subscription unavailable through dedicated gateways'
    end

    def find_core(config)
      candidates = [ENV['MPK_MIHOMO'], config['mihomo']]
      candidates += ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |p| File.join(p, 'mihomo') }
      # Optional discovery only. Never read or update this application's data.
      candidates << '/Applications/Clash Party.app/Contents/Resources/sidecar/mihomo'
      core = candidates.compact.find { |p| File.file?(p) && File.executable?(p) }
      raise Error, 'mihomo required: install it or set MPK_MIHOMO' unless core
      File.expand_path(core)
    end

    def read_settings(path)
      path = private_path!(path)
      return JSON.parse(File.read(path)) unless File.extname(path).downcase == '.txt'

      sources = {}
      File.foreach(path, encoding: 'UTF-8') do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#')
        key, value = line.split('=', 2).map(&:strip)
        key = key.to_s.downcase
        raise Error, '订阅地址文件格式有误：每行请填写 机场名=地址' unless %w[ssone tnt zodaccyes].include?(key) && value && !value.empty? && !sources.key?(key)
        sources[key] = { 'url' => value }
      end
      raise Error, '订阅地址文件需要填写 ssone、tnt 和 zodaccyes 三个地址' unless sources.keys.sort == %w[ssone tnt zodaccyes]
      root = File.dirname(File.expand_path(path))
      { 'sources' => sources, 'mihomo' => File.join(root, 'runtime/local-policy/bin/mihomo'),
        'geodata_dir' => File.join(root, 'runtime/local-policy/geodata') }
    end

    def private_path!(path)
      expanded = File.expand_path(path)
      ancestor = expanded
      ancestor = File.dirname(ancestor) until File.exist?(ancestor)
      resolved = File.realpath(ancestor) + expanded.delete_prefix(ancestor)
      directory = File.directory?(resolved) ? resolved : File.dirname(resolved)
      loop do
        raise Error, 'Private subscription settings and data must be outside a Git repository' if File.exist?(File.join(directory, '.git'))
        parent = File.dirname(directory)
        break if parent == directory
        directory = parent
      end
      expanded
    end

    def build(settings, output)
      raise Error, 'Ruby 3 or newer required by the upstream Normal provider' if RUBY_VERSION.to_f < 3.0
      config = read_settings(settings)
      core = find_core(config)
      sources = config.fetch('sources')
      raise Error, 'exactly ssone, tnt and zodaccyes sources required' unless sources.keys.sort == %w[ssone tnt zodaccyes]
      FileUtils.mkdir_p(File.dirname(output))
      lock_path = File.join(File.dirname(File.expand_path(settings)), '.generate.lock')
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        raise Error, 'another generation is running' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        Dir.mktmpdir('mpk-personal-') do |work|
          File.chmod(0o700, work)
          documents = {}
          sources.each do |name, source|
            puts "[source] #{name}: downloading directly"
            initial = fetch!(source, File.join(work, "#{name}.yaml"))
            documents[name] = name == 'zodaccyes' ? fetch_gated!(source, initial, core, work) : initial
            puts "[source] #{name}: fresh nodes=#{Array(documents[name]['proxies']).size}"
          end
          require_relative 'services/build_pipeline'
          path = File.join(work, 'compiled.yaml')
          # Execute the external Normal provider, without copying its rule source.
          # The upstream writes Ruby diagnostics to a fixed /tmp log by default.
          # Redirect that log into this private temporary directory at runtime.
          upstream = File.join(ROOT, 'vendor/OpenClash(mihomo).sh')
          unless File.file?(upstream)
            upstream = File.join(work, 'upstream-normal.sh')
            run!('curl', '--silent', '--fail', '--location', '--connect-timeout', '10', '--max-time', '45',
                 'https://raw.githubusercontent.com/IvanSolis1989/Smart-Config-Kit/main/OpenClash/OpenClash%28mihomo%29.sh',
                 '--output', upstream, label: 'upstream Normal script download')
          end
          private_upstream = File.join(work, 'normal-private-log.sh')
          log_path = File.join(work, 'provider-private.log')
          write_private(private_upstream, File.read(upstream).sub('LOG_FILE="/tmp/openclash.log"', "LOG_FILE=#{log_path.inspect}"))
          build_config = BuildHelpers.load_config(File.join(ROOT, 'config/config.example.yaml'))
          build_config['provider'] = 'smart-config-kit'
          build_config['policy_preset'] = 'three-source-ai'
          build_config['policy_runtime'] = { 'mihomo' => core, 'geodata_dir' => config['geodata_dir'] }
          build_config['provider_options']['smart_config_kit']['local_script'] = private_upstream
          build_config['custom_rules'] = { 'files' => [] }
          build_config['outputs'] = ['mihomo']
          build_config['output'] = { 'mihomo' => path }
          BuildHelpers.with_private_logs do
            Services::BuildPipeline.new(log: proc { |_| }).build(build_config, policy_documents: documents)
          end
          built = load_yaml(path)
          # Same-filesystem rename: failed generation never replaces the last file.
          stage = output + ".#{Process.pid}.tmp"
          begin
            write_private(stage, File.read(path))
            File.rename(stage, output)
          ensure
            File.unlink(stage) if File.exist?(stage)
          end
          puts "[validate] isolation, multipliers, references, node counts and mihomo -t OK"
          GROUPS.each_value { |g| puts "[AI] #{g}: #{built['proxy-groups'].find { |x| x['name'] == g }['proxies'].size} nodes" }
          puts "[build] #{output} (#{built['proxies'].size} nodes; #{built['proxy-groups'].size} groups)"
        end
      end
    rescue Error
      raise
    rescue StandardError
      raise Error, 'generation failed; previous output retained (private details suppressed)'
    end
  end
end
