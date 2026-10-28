#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/personal_policy'

begin
  default_settings = if RUBY_PLATFORM.include?('darwin')
                       '/Volumes/1TB/个人工具/mihomo-policy-kit/订阅地址.txt'
                     else
                       File.join(ENV.fetch('XDG_CONFIG_HOME', File.join(Dir.home, '.config')), 'mihomo-policy-kit', 'sources.json')
                     end
  settings = File.expand_path(ARGV[0] || ENV['MPK_SOURCES_FILE'] || default_settings)
  output = ARGV[1] ? File.expand_path(ARGV[1]) : File.join(Dir.home, 'Downloads', 'mihomo-personal.yaml')
  MPK::PersonalPolicy.build(settings, output)
rescue MPK::PersonalPolicy::Error => e
  warn "[ERROR] #{e.message}"
  exit 1
end
