# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'tempfile'
require 'open3'
require 'shellwords'

ROOT_DIR = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT_DIR, 'lib'))
require 'overlay'
require 'build_helpers'

begin
  config_path = ARGV[0] || File.join(ROOT_DIR, 'config', 'config.yaml')
  config_path = BuildHelpers.absolute(config_path) unless config_path.start_with?('/')

  unless File.file?(config_path)
    raise MPK::Error, "config not found: #{config_path}\ncopy config/config.example.yaml to config/config.yaml first"
  end

  config = BuildHelpers.load_config(config_path)

  # 可选第二参数覆盖 DNS Profile（upstream / china_compat），供 smoke 测试
  # 一条命令分别验证两套 DNS 行为，不必维护两份 config。
  dns_override = ARGV[1].to_s
  unless dns_override.empty?
    config['patches'] = {} unless config['patches'].is_a?(Hash)
    config['patches']['dns_profile'] = dns_override
  end

  # 可选第三参数覆盖输出路径（供 smoke 测试保留多份明确命名产物）。
  output_override = ARGV[2].to_s
  unless output_override.empty?
    config['output'] = {} unless config['output'].is_a?(Hash)
    config['output']['mihomo'] = output_override
  end

  provider_name = config['provider'].to_s
  raise MPK::Error, "unsupported provider: #{provider_name}" unless provider_name == 'smart-config-kit'

  group_map_path = BuildHelpers.absolute(BuildHelpers.dig(config, 'groups', 'map_file'))
  group_map = MPK::YAMLUtil.load_file(group_map_path)
  overlay = MPK::Overlay.new(config: config, group_map: group_map)

  Dir.mktmpdir('mihomo-policy-kit-') do |work_dir|
    working_yaml = File.join(work_dir, 'source.yaml')

    source_file = BuildHelpers.dig(config, 'source', 'file')
    if source_file && !source_file.to_s.strip.empty?
      source_path = BuildHelpers.absolute(source_file)
      raise MPK::Error, "source file not found: #{source_path}" unless File.file?(source_path)

      puts "[source] use local file: #{source_path}"
      FileUtils.cp(source_path, working_yaml)
    else
      env_name = BuildHelpers.dig(config, 'source', 'url_env', default: 'MPK_SOURCE_URL').to_s
      source_url = ENV[env_name].to_s.strip
      raise MPK::Error, "environment variable #{env_name} is empty" if source_url.empty?

      puts "[source] download subscription from #{env_name}"
      BuildHelpers.fetch_to(source_url, working_yaml, log: "$#{env_name}")
    end

    # 机场订阅可能是 Mihomo YAML 或 base64 节点 URI 列表；先规范化再统计。
    source_format, uri_count = BuildHelpers.normalize_subscription_file(working_yaml)
    puts "[source] format=#{source_format}"

    source_document = MPK::YAMLUtil.load_file(working_yaml)
    source_proxy_count = Array(source_document['proxies']).length
    source_provider_count = source_document['proxy-providers'].is_a?(Hash) ? source_document['proxy-providers'].length : 0
    source_proxy_count = uri_count if source_format == :uri_list && source_proxy_count.zero?
    puts "[source] proxies=#{source_proxy_count} proxy-providers=#{source_provider_count}"

    if source_proxy_count.zero? && source_provider_count.zero?
      raise MPK::Error, 'source subscription contains neither proxies nor proxy-providers'
    end

    provider_script = File.join(ROOT_DIR, 'providers', 'smart-config-kit', 'provider.sh')
    provider_local = BuildHelpers.absolute(
      BuildHelpers.dig(config, 'provider_options', 'smart_config_kit', 'local_script', default: './vendor/OpenClash(mihomo).sh')
    )
    provider_remote = BuildHelpers.dig(
      config,
      'provider_options', 'smart_config_kit', 'remote_url',
      default: 'https://raw.githubusercontent.com/IvanSolis1989/Smart-Config-Kit/main/OpenClash/OpenClash%28mihomo%29.sh'
    ).to_s

    # Windows 下把脚本与目标文件路径转为 Git Bash 可解析的 POSIX 形式，
    # 避免 "F:\..." / "C:\..." 路径在 bash 中解析失败（Issue #7-05）。
    bash_provider_script = BuildHelpers.bash_path_for(provider_script)
    bash_working_yaml = BuildHelpers.bash_path_for(working_yaml)
    bash_provider_local = BuildHelpers.bash_path_for(provider_local)

    # Open3 的 env 参数在 Windows -> WSL bash 场景下不可靠，因此改用
    # bash -c 内联环境赋值，确保 provider 能拿到本地 upstream 路径。
    provider_command = "MPK_PROVIDER_LOCAL=#{Shellwords.escape(bash_provider_local)} " \
                       "MPK_PROVIDER_REMOTE=#{Shellwords.escape(provider_remote)} " \
                       "bash #{Shellwords.escape(bash_provider_script)} #{Shellwords.escape(bash_working_yaml)}"
    BuildHelpers.run_streaming({}, 'bash', '-c', provider_command)

    transformed = MPK::YAMLUtil.load_file(working_yaml)
    after_provider_proxy_count = Array(transformed['proxies']).length
    puts "[provider] proxies after transform=#{after_provider_proxy_count}"

    if source_proxy_count.positive? && after_provider_proxy_count.zero?
      raise MPK::Error, "provider removed all proxies: source=#{source_proxy_count}, transformed=0"
    end

    overlay.apply!(transformed, root_dir: ROOT_DIR)
    stats = overlay.validate!(transformed, source_proxy_count: source_proxy_count)

    output_path = BuildHelpers.absolute(BuildHelpers.dig(config, 'output', 'mihomo', default: './dist/mihomo.yaml'))
    BuildHelpers.write_and_test(transformed, output_path)

    puts '[build] success'
    puts "[build] output=#{output_path}"
    puts "[build] proxies=#{stats[:proxies]} proxy-providers=#{stats[:proxy_providers]} proxy-groups=#{stats[:proxy_groups]} rules=#{stats[:rules]}"
  end
rescue MPK::Error => e
  warn "[ERROR] #{e.message}"
  exit 1
rescue StandardError => e
  warn "[ERROR] unexpected #{e.class}: #{e.message}"
  warn e.backtrace.join("\n") if ENV['MPK_DEBUG'] == '1'
  exit 1
end
