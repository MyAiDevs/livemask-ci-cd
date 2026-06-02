#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_FILE="${1:-${ROOT_DIR}/scripts/role-engine-flow.yml}"

ruby - "${FLOW_FILE}" <<'RUBY'
require "yaml"

path = ARGV.fetch(0)
flow = YAML.load_file(path)
abort("#{path}: root must be a mapping") unless flow.is_a?(Hash)

required_root = %w[schema_version name global role_sequence roles modes]
missing_root = required_root.reject { |key| flow.key?(key) }
abort("#{path}: missing root key(s): #{missing_root.join(", ")}") unless missing_root.empty?

roles = flow["roles"]
abort("#{path}: roles must be a mapping") unless roles.is_a?(Hash)

required_roles = %w[pm product tech qa task-review]
missing_roles = required_roles.reject { |role| roles.key?(role) }
abort("#{path}: missing role(s): #{missing_roles.join(", ")}") unless missing_roles.empty?

sequence = flow["role_sequence"]
abort("#{path}: role_sequence must be an array") unless sequence.is_a?(Array)
unless sequence[0, required_roles.length] == required_roles
  abort("#{path}: role_sequence must begin with #{required_roles.join(" -> ")}")
end

required_role_keys = %w[phase purpose required_inputs allowed_actions forbidden_actions must_emit exit_gates]
roles.each do |role, rule|
  abort("#{path}: role #{role.inspect} must be a mapping") unless rule.is_a?(Hash)
  missing = required_role_keys.reject { |key| rule.key?(key) }
  abort("#{path}: role #{role.inspect} missing key(s): #{missing.join(", ")}") unless missing.empty?
  required_role_keys.each do |key|
    next if %w[phase purpose].include?(key)
    value = rule[key]
    abort("#{path}: role #{role.inspect} #{key} must be a non-empty array") unless value.is_a?(Array) && !value.empty?
  end
end

global = flow["global"]
abort("#{path}: global must be a mapping") unless global.is_a?(Hash)
%w[required_before_any_role hard_completion_gates forbidden_global_actions].each do |key|
  value = global[key]
  abort("#{path}: global #{key} must be a non-empty array") unless value.is_a?(Array) && !value.empty?
end

modes = flow["modes"]
abort("#{path}: modes must be a mapping") unless modes.is_a?(Hash)
%w[all --deep-review --closure-audit --impact-analysis].each do |mode|
  abort("#{path}: missing mode #{mode.inspect}") unless modes.key?(mode)
end

puts "role-engine flow contract PASS: #{path}"
puts "roles: #{required_roles.join(", ")}"
puts "hard completion gates: #{global["hard_completion_gates"].length}"
RUBY
