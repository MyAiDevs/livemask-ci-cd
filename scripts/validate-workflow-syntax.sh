#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "=== Validate GitHub workflow YAML ==="
ruby <<'RUBY'
require "yaml"

required = {
  ".github/workflows/staging-smoke.yml" => {
    "name" => "Staging Smoke",
    "jobs" => ["smoke", "notify-lark"],
  },
  ".github/workflows/dev-runtime-deploy.yml" => {
    "name" => "Dev Runtime Deploy",
    "jobs" => ["deploy", "notify-lark"],
  },
  ".github/workflows/ci-runner-diagnostics.yml" => {
    "name" => "CI Runner Diagnostics",
    "jobs" => ["runner-ops"],
  },
}

Dir.glob(".github/workflows/*.{yml,yaml}").sort.each do |path|
  data = YAML.load_file(path)
  unless data.is_a?(Hash)
    abort("#{path}: workflow YAML did not parse to a mapping")
  end
  name = data["name"]
  jobs = data["jobs"]
  abort("#{path}: missing workflow name") if name.to_s.strip.empty?
  abort("#{path}: missing jobs mapping") unless jobs.is_a?(Hash) && !jobs.empty?
  puts "#{path}: #{name} (#{jobs.keys.join(", ")})"
end

required.each do |path, rule|
  abort("#{path}: missing required workflow") unless File.exist?(path)
  data = YAML.load_file(path)
  actual_name = data["name"].to_s
  expected_name = rule["name"]
  abort("#{path}: expected name #{expected_name.inspect}, got #{actual_name.inspect}") unless actual_name == expected_name

  jobs = data["jobs"] || {}
  rule["jobs"].each do |job_name|
    abort("#{path}: missing required job #{job_name.inspect}") unless jobs.key?(job_name)
  end
end
RUBY

echo
echo "=== Validate shell syntax ==="
bash -n .github/scripts/*.sh scripts/*.sh

echo
echo "Workflow syntax guard PASS"
