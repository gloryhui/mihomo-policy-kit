# frozen_string_literal: true

# Optional CLI for the same persisted Sources/Profiles as Web. Existing mpk
# commands remain independent of the Web dependencies.
require 'bundler/setup'
require_relative '../lib/web/runtime'

begin
  app = MPK::Web::Runtime.app
  service = app.opts[:control_plane]
  result = service.locked do
    case ARGV[0]
    when 'sources' then service.sources.list
    when 'refresh' then service.sources.refresh(Integer(ARGV.fetch(1)))
    when 'profiles' then service.profiles
    when 'build' then service.build(Integer(ARGV.fetch(1)))
    else abort 'Usage: ruby scripts/control.rb sources|refresh <id>|profiles|build <id>'
    end
  end
  puts JSON.pretty_generate(result)
rescue StandardError
  warn '[ERROR] Control operation failed; check IDs, dependencies and master key.'
  exit 1
end
