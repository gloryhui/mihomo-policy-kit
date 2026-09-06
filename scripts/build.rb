# frozen_string_literal: true

require 'yaml'
require 'fileutils'
require 'tmpdir'
require 'tempfile'
require 'open3'

ROOT_DIR = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT_DIR, 'lib'))
require 'overlay'

module BuildHelpers
  module_function

  def absolute(path)
    File.expand_path(path.to_s, ROOT_DIR)
  end

  def load_config(path)
    MPK::YAMLUtil.load_file(path)
  end

  def dig(hash, *keys, default: nil)
    current = hash
    keys.each do |key|
      return default unless current.is_a?(Hash) && current.key?(key)

      current = current[key]
    end
    current.nil? ? default : current
  end

  def run_streaming(env, *command)
    puts "[exec] #{command.join(' ')}"
    status = nil

    Open3.popen2e(env, *command) do |_stdin, output, wait_thread|
      output.each { |line| $stdout.write(line) }
      status = wait_thread.value
    end

    raise MPK::Error, "command failed (#{status.exitstatus}): #{command.join(' ')}" unless status.success?
  end

  def fetch_to(url, path)
    FileUtils.mkdir_p(File.dirname(path))
    run_streaming(
      {},
      'curl', '-fL', '--connect-timeout', '15', '--retry', '3', '--retry-delay', '2',
      url, '-o', path
    )
  end

  def command_available?(command)
    system('sh', '-c', "command -v #{command} >/dev/null 2>&1")
  end

  def write_and_test(document, output_path)
    FileUtils.mkdir_p(File.dirname(output_path))

    Tempfile.create(['mpk-candidate-', '.yaml'], File.dirname(output_path)) do |tmp|
      tmp.write(YAML.dump(document))
      tmp.flush
      tmp.fsync

      if command_available?('mihomo')
        puts '[validate] running mihomo -t'
        stdout, stderr, status = Open3.capture3('mihomo', '-t', '-f', tmp.path)
        $stdout.write(stdout) unless stdout.empty?
        $stderr.write(stderr) unless stderr.empty?
        raise MPK::Error, "mihomo config test failed (#{status.exitstatus})" unless status.success?
      else
        puts '[validate] mihomo not found; core validation skipped'
      end

      FileUtils.mv(tmp.path, output_path)
    end
  end
end

begin
  config_path = ARGV[0] || File.join(ROOT_DIR, 'config', 'config.yaml')
  config_path = BuildHelpers.absolute(config_path) unless config_path.start_with?('/')

  unless File.file?(config_path)
    raise MPK::Error, "config not found: #{config_path}\ncopy config/config.example.yaml to config/config.yaml first"
  end

  config = BuildHelpers.load_config(config_path)
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
      BuildHelpers.fetch_to(source_url, working_yaml)
    end

    source_document = MPK::YAMLUtil.load_file(working_yaml)
    source_proxy_count = Array(source_document['proxies']).length
    source_provider_count = source_document['proxy-providers'].is_a?(Hash) ? source_document['proxy-providers'].length : 0
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

    BuildHelpers.run_streaming(
      {
        'MPK_PROVIDER_LOCAL' => provider_local,
        'MPK_PROVIDER_REMOTE' => provider_remote
      },
      'bash', provider_script, working_yaml
    )

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
