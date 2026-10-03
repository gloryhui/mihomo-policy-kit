# frozen_string_literal: true

require 'minitest/autorun'
require 'rack/test'
require 'tmpdir'
require 'open3'
require_relative '../lib/web/app'

class WebPublisherTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    skip 'Publisher production filesystem integration runs on Linux' if Gem.win_platform?
    @dir = Dir.mktmpdir('mpk-web-publisher-')
    @db = MPK::Services::Database.open(File.join(@dir, 'mpk.db'))
    @control = MPK::Services::ControlPlane.new(db: @db, data_root: @dir, crypto: MPK::Services::Crypto.new('e5' * 32))
    @app = Class.new(MPK::Web::App)
    @app.opts[:control_plane] = @control
    @app.opts[:public_origin] = 'https://example.invalid'
    header 'Host', 'localhost'
    header 'X-MPK-Request', '1'
    header 'Content-Type', 'application/json'
  end

  def teardown
    @db&.disconnect
    FileUtils.remove_entry(@dir) if @dir
  end

  def app
    @app.app
  end

  def parsed
    JSON.parse(last_response.body)
  end

  def post_json(path, data = {})
    post '/api/v1/' + path, JSON.generate(data)
  end

  def create_build(port)
    content = YAML.dump('proxies' => [{ 'name' => "日本#{port}", 'type' => 'ss', 'server' => '127.0.0.1', 'port' => port,
      'cipher' => 'aes-128-gcm', 'password' => 'VERY_SECRET_WEB_PUBLISH_PASSWORD' }])
    source = @control.sources.save({ 'name' => 'fixture', 'input_kind' => 'inline', 'content' => content })
    @control.sources.refresh(source[:id])
    profile = @control.save_profile({ 'name' => 'fixture', 'provider' => 'acl4ssr', 'source_ids' => [source[:id]] })
    @control.build(profile[:id])
  end

  def test_web_publish_token_once_rollback_revoke_and_cli_shared_state
    first = create_build(8801)
    post_json('publisher/publish', build_id: first[:id])
    assert_equal 200, last_response.status, last_response.body
    first_id = parsed['current']
    post_json('publisher/tokens', name: 'fixture-phone')
    assert_equal 201, last_response.status, last_response.body
    url = parsed['url']
    token = url.split('/')[-2]
    refute parsed.key?('token')
    public_path = File.join(@dir, 'public', 'sub', token, 'mihomo.yaml')
    initial = File.binread(public_path)
    get '/api/v1/publisher/status'
    refute_includes last_response.body, token
    refute_includes last_response.body, 'VERY_SECRET'
    get '/api/v1/publisher/tokens'
    refute_includes last_response.body, token
    assert_equal true, parsed.first['active']
    second = create_build(8802)
    post_json('publisher/publish', build_id: second[:id])
    assert_equal 200, last_response.status
    refute_equal initial, File.binread(public_path)
    post_json('publisher/rollback')
    assert_equal first_id, parsed['current']
    assert_equal initial, File.binread(public_path)
    stdout, stderr, status = Open3.capture3({ 'MPK_PUBLISH_ROOT' => @dir }, RbConfig.ruby,
      File.expand_path('../scripts/publisher.rb', __dir__), 'status')
    assert status.success?, stderr
    assert_includes stdout, first_id
    refute_includes stdout, token
    delete '/api/v1/publisher/tokens/fixture-phone'
    assert_equal 200, last_response.status
    refute File.exist?(public_path)
    get '/api/v1/publisher/tokens'
    assert_equal false, parsed.first['active']
    refute_includes JSON.generate(@db[:build_records].all), token
  end

  def test_failure_paths_preserve_publisher_current_and_never_echo_credentials
    post_json('publisher/rollback')
    assert_equal 422, last_response.status
    post_json('publisher/publish', build_id: 999)
    assert_equal 404, last_response.status
    first = create_build(8801)
    post_json('publisher/publish', build_id: first[:id])
    current = parsed['current']
    row = @db[:build_records][id: first[:id]]
    File.binwrite(row[:artifact_path], 'invalid VERY_SECRET_CORRUPTED_ARTIFACT')
    post_json('publisher/publish', build_id: first[:id])
    assert_equal 422, last_response.status
    refute_includes last_response.body, 'VERY_SECRET'
    get '/api/v1/publisher/status'
    assert_equal current, parsed['current']
  end
end
