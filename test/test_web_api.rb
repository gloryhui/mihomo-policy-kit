# frozen_string_literal: true

require 'minitest/autorun'
require 'rack/test'
require 'tmpdir'
require_relative '../lib/web/app'

class WebApiTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @dir = Dir.mktmpdir('mpk-api-')
    @db = MPK::Services::Database.open(File.join(@dir, 'mpk.db'))
    @control = MPK::Services::ControlPlane.new(db: @db, data_root: @dir, crypto: MPK::Services::Crypto.new('c3' * 32))
    @app = Class.new(MPK::Web::App)
    @app.opts[:control_plane] = @control
    @app.opts[:public_origin] = 'https://example.invalid'
    header 'Host', 'localhost'
    header 'X-MPK-Request', '1'
    header 'Content-Type', 'application/json'
  end

  def teardown
    @db.disconnect
    FileUtils.remove_entry(@dir)
  end

  def app
    @app.app
  end

  def parsed
    JSON.parse(last_response.body)
  end

  def write(method, path, value = {})
    public_send(method, '/api/v1/' + path, JSON.generate(value))
  end

  def test_source_crud_and_secret_redaction
    write(:post, 'sources', name: 'fixture', subscription_url: 'https://example.invalid/VERY_SECRET_API_TOKEN')
    assert_equal 201, last_response.status, last_response.body
    id = parsed['id']
    refute_includes last_response.body, 'VERY_SECRET'
    get '/api/v1/sources'
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'subscription_url'
    write(:patch, "sources/#{id}", name: 'renamed')
    assert_equal 'renamed', parsed['name']
    write(:delete, "sources/#{id}")
    assert_equal true, parsed['deleted']
    write(:post, "sources/#{id}/refresh")
    assert_equal 404, last_response.status
  end

  def test_api_profile_nodes_build_dashboard_happy_path
    content = YAML.dump('proxies' => [{ 'name' => '日本-2x', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 9999, 'cipher' => 'aes-128-gcm', 'password' => 'VERY_SECRET_API_PASSWORD' }])
    write(:post, 'sources', name: 'fixture', input_kind: 'inline', content: content)
    source_id = parsed['id']
    write(:post, "sources/#{source_id}/refresh")
    assert_equal 200, last_response.status, last_response.body
    write(:post, 'profiles', name: 'fixture', provider: 'acl4ssr', source_ids: [source_id])
    profile_id = parsed['id']
    assert_equal 201, last_response.status
    get '/api/v1/nodes', profile_id: profile_id
    assert_equal 200, last_response.status
    node_id = parsed['items'][0]['id']
    refute_includes last_response.body, 'VERY_SECRET'
    refute_includes last_response.body, 'proxy_ciphertext'
    write(:patch, "nodes/#{node_id}/selection", profile_id: profile_id, selection: 'include')
    assert_equal 200, last_response.status
    write(:post, "profiles/#{profile_id}/build")
    assert_equal 201, last_response.status, last_response.body
    assert_equal 'success', parsed['status']
    refute_includes last_response.body, 'artifact_path'
    get '/api/v1/builds'
    assert_equal 1, parsed.length
    get '/api/v1/dashboard'
    assert_equal 1, parsed['source_count']
    get '/api/v1/health'
    assert_equal 'ok', parsed['status']
    write(:delete, "profiles/#{profile_id}")
    assert_equal true, parsed['deleted']
  end

  def test_validation_and_uniform_errors
    write(:post, 'sources', name: 'fixture', subscription_url: 'http://example.invalid/VERY_SECRET_API_TOKEN')
    assert_equal 422, last_response.status
    assert parsed['error']['code']
    refute_includes last_response.body, 'VERY_SECRET'
    post '/api/v1/sources', '{invalid'
    assert_equal 400, last_response.status
    get '/api/v1/nodes', page: '-1'
    assert_equal 422, last_response.status
    get '/api/v1/not-a-route'
    assert_equal 404, last_response.status
  end

  def test_csrf_host_and_production_auth_boundary
    header 'X-MPK-Request', nil
    write(:post, 'sources')
    assert_equal 403, last_response.status
    header 'X-MPK-Request', '1'
    header 'Origin', 'https://attacker.invalid'
    write(:post, 'sources')
    assert_equal 403, last_response.status
    header 'Origin', nil
    header 'Host', 'attacker.invalid'
    get '/api/v1/health'
    assert_equal 403, last_response.status
    header 'Host', 'localhost'
    @app.opts[:production] = true
    get '/api/v1/health'
    assert_equal 401, last_response.status
    header 'X-MPK-Authenticated', 'fixture-admin'
    get '/api/v1/health'
    assert_equal 200, last_response.status
  end
end
