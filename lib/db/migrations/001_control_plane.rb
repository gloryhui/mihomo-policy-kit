# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:sources) do
      primary_key :id
      String :name, null: false
      TrueClass :enabled, null: false, default: true
      String :input_kind, null: false, default: 'remote'
      String :subscription_url_ciphertext, text: true, null: false
      String :subscription_url_iv, null: false
      String :subscription_url_tag, null: false
      String :name_prefix, null: false, default: ''
      Float :max_multiplier
      String :unknown_multiplier_action, null: false, default: 'allow'
      Integer :refresh_interval, null: false, default: 3600
      String :last_refresh_at
      String :last_status, null: false, default: 'never'
      String :last_error_safe
      String :created_at, null: false
      String :updated_at, null: false
      check(input_kind: %w[remote inline])
      check(unknown_multiplier_action: %w[allow remove])
    end
    create_table(:nodes) do
      primary_key :id
      foreign_key :source_id, :sources, null: false, on_delete: :cascade
      String :fingerprint, null: false
      String :original_name, null: false
      String :display_name, null: false
      String :protocol, null: false
      String :server, null: false
      Integer :port, null: false
      String :region, null: false
      Float :multiplier
      TrueClass :available, null: false, default: true
      String :first_seen_at, null: false
      String :last_seen_at, null: false
      String :metadata_json, null: false, default: '{}'
      String :proxy_ciphertext, text: true, null: false
      String :proxy_iv, null: false
      String :proxy_tag, null: false
      unique [:source_id, :fingerprint]
    end
    create_table(:profiles) do
      primary_key :id
      String :name, null: false
      String :provider, null: false
      String :dns_profile, null: false
      TrueClass :enabled, null: false, default: true
      String :created_at, null: false
      String :updated_at, null: false
      check(provider: %w[smart-config-kit acl4ssr])
      check(dns_profile: %w[upstream china_compat])
    end
    create_table(:profile_sources) do
      foreign_key :profile_id, :profiles, null: false, on_delete: :cascade
      foreign_key :source_id, :sources, null: false, on_delete: :cascade
      primary_key [:profile_id, :source_id]
    end
    create_table(:node_selections) do
      foreign_key :profile_id, :profiles, null: false, on_delete: :cascade
      foreign_key :node_id, :nodes, null: false, on_delete: :cascade
      String :selection, null: false
      primary_key [:profile_id, :node_id]
      check(selection: %w[auto include exclude])
    end
    create_table(:build_records) do
      primary_key :id
      foreign_key :profile_id, :profiles, on_delete: :set_null
      String :profile_name, null: false
      String :status, null: false
      Integer :source_count, null: false, default: 0
      Integer :original_node_count, null: false, default: 0
      Integer :selected_node_count, null: false, default: 0
      Integer :final_node_count, null: false, default: 0
      String :artifact_path
      String :error_safe
      String :created_at, null: false
      String :finished_at
    end
    create_table(:settings) do
      String :key, primary_key: true
      String :value, null: false
    end
  end
end
