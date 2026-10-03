# frozen_string_literal: true

require 'minitest/autorun'

class WebDeployTest < Minitest::Test
  def test_nginx_keeps_private_data_outside_the_web_root_and_authenticates_management
    config = File.read(File.expand_path('../deploy/nginx/mpk-web-console.conf.example', __dir__))
    assert_includes config, 'root /var/lib/mihomo-policy-kit/public;'
    refute_match(/root \/var\/lib\/mihomo-policy-kit;/, config)
    assert_equal 2, config.scan('auth_basic_user_file /etc/nginx/mpk.htpasswd;').length
    assert_includes config, 'proxy_set_header X-MPK-Authenticated $remote_user;'
    assert_includes config, 'proxy_set_header Authorization "";'
    assert_includes config, 'auth_basic off;'
    assert_includes config, 'access_log off;'
    assert_includes config, 'log_not_found off;'
  end

  def test_service_loads_external_secrets_and_the_server_binds_only_loopback
    service = File.read(File.expand_path('../deploy/systemd/mpk-web.service.example', __dir__))
    server = File.read(File.expand_path('../scripts/web.rb', __dir__))
    assert_includes service, 'EnvironmentFile=/etc/mihomo-policy-kit/web.env'
    assert_includes service, 'UMask=0027'
    refute_includes service, 'MPK_MASTER_KEY='
    assert_includes server, "server.add_tcp_listener('127.0.0.1', port)"
  end
end
