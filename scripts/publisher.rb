# frozen_string_literal: true

# mihomo-policy-kit Publisher CLI（V0.2）
#
# 用法：
#   ruby scripts/publisher.rb init
#   ruby scripts/publisher.rb publish <mihomo.yaml>
#   ruby scripts/publisher.rb status
#   ruby scripts/publisher.rb rollback
#   ruby scripts/publisher.rb token create <name>
#   ruby scripts/publisher.rb token list
#   ruby scripts/publisher.rb token revoke <name>
#
# 环境变量：
#   MPK_PUBLISH_ROOT      publish root（默认 ./runtime）
#   MPK_PUBLIC_BASE_URL   https://<host>/ 用于 token create 输出完整订阅 URL
#   MPK_CONFIG            config 文件（用于复用 Overlay 校验；可选）

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'overlay'
require 'publisher/publisher'

ROOT_DIR = File.expand_path('..', __dir__)

def publish_root
  env = ENV['MPK_PUBLISH_ROOT'].to_s.strip
  return env unless env.empty?

  File.expand_path('runtime', ROOT_DIR)
end

def load_config
  config_path = ENV['MPK_CONFIG'].to_s.strip
  return nil if config_path.empty?

  config_path = File.expand_path(config_path, ROOT_DIR)
  return nil unless File.file?(config_path)

  MPK::YAMLUtil.load_file(config_path)
rescue MPK::Error
  nil
end

def publisher
  @publisher ||= MPK::Publisher::Publisher.new(
    root: publish_root,
    config: load_config,
    env: ENV
  ).tap(&:init!)
end

def public_base_url
  ENV['MPK_PUBLIC_BASE_URL'].to_s.strip
end

def print_status(status)
  puts "[publisher] root=#{status[:root]}"
  puts "[publisher] current=#{status[:current] || '(none)'}"
  puts "[publisher] previous=#{status[:previous] || '(none)'}"
  puts "[publisher] builds=#{status[:builds].length}"
  status[:builds].each { |id| puts "  - #{id}" }
  puts "[publisher] tokens=#{status[:tokens].length}"
  status[:tokens].each do |token|
    state = token['active'] ? 'active' : 'revoked'
    puts "  - #{token['name']} #{state} fp=#{token['fingerprint']} created=#{token['created_at']}"
  end
end

def cmd_init
  publisher
  puts "[publisher] initialized: #{publish_root}"
end

def cmd_publish(artifact)
  raise MPK::Error, "usage: mpk publish <mihomo.yaml>" if artifact.nil? || artifact.empty?

  result = publisher.publish(artifact, public_base_url: public_base_url)
  action = result[:published] ? 'published' : 'unchanged (idempotent)'
  puts "[publish] #{action} build_id=#{result[:build_id]}"
  puts "[publish] current=#{result[:current] || '(none)'}"
  puts "[publish] previous=#{result[:previous] || '(none)'}"
  stats = result[:stats]
  puts "[publish] proxies=#{stats[:proxies]} proxy-providers=#{stats[:proxy_providers]} proxy-groups=#{stats[:proxy_groups]} rules=#{stats[:rules]}"
  puts "[publish] mihomo -t=#{stats[:mihomo_tested] ? 'ok' : 'skipped (not installed)'}"
end

def cmd_status
  print_status(publisher.status)
end

def cmd_rollback
  result = publisher.rollback
  puts "[rollback] current=#{result[:current]} previous=#{result[:previous]}"
  puts "[rollback] rolled back from #{result[:rolled_back_from]} to #{result[:rolled_back_to]}"
end

def cmd_token_create(name)
  raise MPK::Error, 'usage: mpk token create <name>' if name.nil? || name.empty?
  raise MPK::Error, 'MPK_PUBLIC_BASE_URL is required to print the subscription URL' if public_base_url.empty?

  result = publisher.create_token(name, public_base_url: public_base_url)
  puts "[token] created name=#{result[:name]} fingerprint=#{result[:fingerprint]}"
  # 完整 token / URL 只在显式 create 时一次性输出（Issue #11 04 / 05）
  puts "[token] subscription URL: #{result[:url]}"
end

def cmd_token_list
  tokens = publisher.list_tokens
  if tokens.empty?
    puts '[token] no tokens'
    return
  end
  tokens.each do |token|
    state = token['active'] ? 'active' : 'revoked'
    puts "#{state.ljust(7)} #{token['name'].ljust(20)} fp=#{token['fingerprint']} created=#{token['created_at']}"
  end
end

def cmd_token_revoke(name)
  raise MPK::Error, 'usage: mpk token revoke <name>' if name.nil? || name.empty?

  fingerprint = publisher.revoke_token(name)
  puts "[token] revoked name=#{name} fingerprint=#{fingerprint}"
end

def usage
  puts <<~USAGE
    mihomo-policy-kit publisher (V0.2)

    Usage:
      ruby scripts/publisher.rb init
      ruby scripts/publisher.rb publish <mihomo.yaml>
      ruby scripts/publisher.rb status
      ruby scripts/publisher.rb rollback
      ruby scripts/publisher.rb token create <name>
      ruby scripts/publisher.rb token list
      ruby scripts/publisher.rb token revoke <name>

    Environment:
      MPK_PUBLISH_ROOT      publish root (default: ./runtime)
      MPK_PUBLIC_BASE_URL   https://<host>/ for stable subscription URL output
      MPK_CONFIG            optional config for reusing Overlay validation
  USAGE
end

begin
  command = ARGV[0]
  case command
  when 'init' then cmd_init
  when 'publish' then cmd_publish(ARGV[1])
  when 'status' then cmd_status
  when 'rollback' then cmd_rollback
  when 'token'
    sub = ARGV[1]
    case sub
    when 'create' then cmd_token_create(ARGV[2])
    when 'list' then cmd_token_list
    when 'revoke' then cmd_token_revoke(ARGV[2])
    else
      usage
      exit 2
    end
  when '-h', '--help', 'help', nil
    usage
  else
    warn "Unknown command: #{command}"
    usage
    exit 2
  end
rescue MPK::Error => e
  warn "[ERROR] #{e.message}"
  exit 1
rescue StandardError => e
  warn "[ERROR] unexpected #{e.class}: #{e.message}"
  warn e.backtrace.join("\n") if ENV['MPK_DEBUG'] == '1'
  exit 1
end
