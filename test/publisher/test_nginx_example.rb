# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/overlay'

# Nginx 示例的确定性文本回归（Issue #11 05/06）。
# 不要求本机有 nginx：这些断言保证安全关键项不会悄悄丢失；
# 有 nginx 的 CI 另外执行 nginx -t 语法验证。
class NginxExampleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CONF = File.join(ROOT, 'deploy', 'nginx', 'mihomo-subscription.conf.example')

  def conf
    @conf ||= File.read(CONF, encoding: 'UTF-8')
  end

  def test_contains_token_location_with_access_log_off
    # 订阅 token 位于 URL path，access log 必须关闭（P0 安全项）
    assert_match(%r{location ~ "?\^/sub/\[A-Za-z0-9_\-\]\{20,\}/mihomo\\\.yaml\$"?}, conf)
    assert_includes conf, 'access_log off'
  end

  def test_contains_log_not_found_off
    assert_includes conf, 'log_not_found off'
  end

  def test_contains_autoindex_off
    assert_includes conf, 'autoindex off'
  end

  def test_contains_robots_noindex
    assert_includes conf, 'X-Robots-Tag'
    assert_includes conf, 'noindex, nofollow, noarchive'
    assert_includes conf, 'robots.txt'
  end

  def test_default_404_for_other_paths
    assert_includes conf, 'return 404'
  end

  def test_placeholder_only_no_real_credentials
    # 示例只允许占位符：不包含真实域名 / 证书文件 / 私钥内容 / token 字面量
    refute_includes conf, 'BEGIN PRIVATE KEY'
    refute_includes conf, 'BEGIN CERTIFICATE'
    refute_match(/server_name\s+(?!<YOUR-DOMAIN>)[\w.-]+/, conf)
    refute_includes conf, '<YOUR-CERT-PATHS>/fullchain'
  end

  def test_https_required_documented
    assert_includes conf, 'listen 443 ssl'
  end
end
