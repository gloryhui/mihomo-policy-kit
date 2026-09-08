# frozen_string_literal: true

# Renders the sing-box adapter output for a sanitized policy and prints the
# JSON to stdout.  Used by CI to run the official `sing-box check -c` against
# the adapter's real output (schema/version compatibility), complementing the
# deterministic Ruby structural validator.
#
# The policy mirrors test/test_output_adapter.rb#supported_policy and uses only
# fake data (IP-literal servers, example.invalid, all-zero UUID, fake password).
# No real subscription URL / token / node credential is ever present.

require_relative '../lib/output_adapter'

policy = {
  'proxies' => [
    { 'name' => 'Fake-SS', 'type' => 'ss', 'server' => '127.0.0.1', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'fake-password-ss' },
    { 'name' => 'Fake-VMess', 'type' => 'vmess', 'server' => '127.0.0.2', 'port' => 443, 'uuid' => '00000000-0000-0000-0000-000000000000', 'cipher' => 'auto', 'alterId' => 0 }
  ],
  'proxy-groups' => [
    { 'name' => 'US', 'type' => 'select', 'proxies' => ['Fake-SS', 'DIRECT'] },
    { 'name' => 'Global', 'type' => 'select', 'proxies' => ['US', 'Fake-VMess', 'DIRECT'] },
    { 'name' => 'Final', 'type' => 'select', 'proxies' => ['Global', 'DIRECT'] }
  ],
  'rules' => ['DOMAIN-SUFFIX,example.invalid,Global', 'IP-CIDR,192.0.2.0/24,DIRECT', 'MATCH,Final']
}

adapter = MPK::OutputRegistry.new.fetch('sing-box')
print adapter.render(policy)
