# frozen_string_literal: true

require 'open3'

ROOT_DIR = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(ROOT_DIR, 'lib'))
require 'overlay'
require 'build_helpers'

path = ARGV[0]
if path.nil? || path.strip.empty?
  warn 'usage: ruby scripts/validate.rb <mihomo.yaml>'
  exit 2
end

path = File.expand_path(path)

begin
  document = MPK::YAMLUtil.load_file(path)

  proxies = Array(document['proxies']).length
  providers = document['proxy-providers'].is_a?(Hash) ? document['proxy-providers'].length : 0
  groups = Array(document['proxy-groups']).length
  rules = Array(document['rules']).length

  raise MPK::Error, 'missing proxies/proxy-providers' if proxies.zero? && providers.zero?
  raise MPK::Error, 'missing proxy-groups' if groups.zero?
  raise MPK::Error, 'missing rules' if rules.zero?

  puts "[validate] YAML OK: proxies=#{proxies} proxy-providers=#{providers} proxy-groups=#{groups} rules=#{rules}"

  if (mihomo = BuildHelpers.command_path('mihomo'))
    stdout, stderr, status = Open3.capture3(mihomo, '-t', '-f', path)
    $stdout.write(stdout) unless stdout.empty?
    $stderr.write(stderr) unless stderr.empty?
    raise MPK::Error, "mihomo config test failed (#{status.exitstatus})" unless status.success?

    puts '[validate] mihomo -t OK'
  else
    puts '[validate] mihomo not found; core validation skipped'
  end
rescue MPK::Error => e
  warn "[ERROR] #{e.message}"
  exit 1
end
