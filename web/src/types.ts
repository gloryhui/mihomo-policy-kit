export type Selection = "auto" | "include" | "exclude";
export interface Source {
  id: number;
  name: string;
  enabled: boolean;
  input_kind: "remote" | "inline";
  secret_configured: boolean;
  name_prefix: string;
  max_multiplier: number | null;
  unknown_multiplier_action: "allow" | "remove";
  refresh_interval: number;
  last_refresh_at: string | null;
  last_status: string;
  last_error_safe: string | null;
  node_count: number;
  available_node_count: number;
}
export interface Profile {
  id: number;
  name: string;
  enabled: boolean;
  provider: string;
  dns_profile: string;
  source_ids: number[];
}
export interface Node {
  id: number;
  original_name: string;
  display_name: string;
  source_name: string;
  source_id: number;
  region: string;
  multiplier: number | null;
  protocol: string;
  available: boolean;
  selected: boolean;
  selection: Selection;
}
export interface Build {
  id: number;
  profile_name: string;
  status: string;
  source_count: number;
  original_node_count: number;
  selected_node_count: number;
  final_node_count: number;
  created_at: string;
  error_safe: string | null;
}
export interface Token {
  name: string;
  fingerprint: string;
  active: boolean;
  created_at: string;
}
export interface Publisher {
  current: string | null;
  previous: string | null;
  builds: string[];
  tokens: Token[];
}
export interface Dashboard {
  source_count: number;
  node_count: number;
  available_node_count: number;
  profile_count: number;
  publisher: Publisher;
  recent_sources: Source[];
  recent_builds: Build[];
}
