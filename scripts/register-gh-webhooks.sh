#!/usr/bin/env bash
# register-gh-webhooks.sh — Register GitHub webhooks on all 8 LiveMask repos.
# Usage: bash scripts/register-gh-webhooks.sh
set -euo pipefail

PAYLOAD_URL="http://47.243.128.122:10086/github-issue"
SECRET="${GH_WEBHOOK_SECRET:-livemask-gh-webhook-2026}"
CONTENT_TYPE="json"
ORG="MyAiDevs"
REPOS=(
  "livemask-docs" "livemask-backend" "livemask-admin" "livemask-app"
  "livemask-website" "livemask-nodeagent" "livemask-job-service" "livemask-ci-cd"
)
EVENTS='["issues","issue_comment","push","ping"]'

echo "=== GitHub Webhook Registration ==="
echo "Payload: ${PAYLOAD_URL}"
echo ""

for repo in "${REPOS[@]}"; do
  full="${ORG}/${repo}"
  echo "--- ${full} ---"
  EXISTING=$(gh api "/repos/${full}/hooks" --jq '.[] | select(.config.url == "'"${PAYLOAD_URL}"'") | .id' 2>/dev/null || echo "")
  if [[ -n "${EXISTING}" ]]; then
    echo "  Updating hook #${EXISTING}..."
    gh api -X PATCH "/repos/${full}/hooks/${EXISTING}" --input - <<HOOK 2>/dev/null || echo "  WARN: update failed"
{"config":{"url":"${PAYLOAD_URL}","content_type":"${CONTENT_TYPE}","secret":"${SECRET}","insecure_ssl":"0"},"events":${EVENTS},"active":true}
HOOK
    echo "  OK"
  else
    echo "  Creating..."
    gh api -X POST "/repos/${full}/hooks" --input - <<HOOK 2>/dev/null || echo "  WARN: create failed"
{"name":"web","active":true,"events":${EVENTS},"config":{"url":"${PAYLOAD_URL}","content_type":"${CONTENT_TYPE}","secret":"${SECRET}","insecure_ssl":"0"}}
HOOK
    echo "  Created"
  fi
done

echo ""
echo "Done — ${#REPOS[@]} repos configured"
echo "Test: create an issue, then check: ssh root@47.243.128.122 tail -F /var/log/livemask-webhook.log"
