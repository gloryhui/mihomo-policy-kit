# frozen_string_literal: true

require 'bundler/setup'
require 'puma'
require_relative '../lib/web/runtime'

port = Integer(ENV.fetch('MPK_WEB_PORT', '9292'))
abort 'MPK_WEB_PORT must be between 1024 and 65535' unless (1024..65_535).cover?(port)
app = MPK::Web::Runtime.app
server = Puma::Server.new(app.app)
server.add_tcp_listener('127.0.0.1', port)
%w[INT TERM].each { |signal| Signal.trap(signal) { server.stop } }
puts "[web] API listening on http://127.0.0.1:#{port}; management UI: /admin/ via Vite or Nginx"
server.run.join
