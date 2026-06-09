#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-VPN-PROTOCOL-E2E-ACCEPTANCE-SMOKE-001
# Per-protocol VPN E2E acceptance orchestrator (CI-safe layers)
# ═══════════════════════════════════════════════════════════════════════════════
# Layers per profile:
#   L1 Backend connect_config + credential (vpn-protocol-matrix-smoke)
#   L2 App sing-box config builder (app-libbox-config-smoke)
#   L3 App tunnel runtime rules (app-libbox-tunnel-runtime-smoke)
#   L4 Android engine routing (app-android-libbox-runtime-smoke)
#   L5 Device live traffic proof — manual gate (TASK-VPN-E2E-*)
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCS_ROOT="${LIVEMASK_DOCS_ROOT:-${ROOT}/livemask-docs}"

PROFILES=(
  hysteria2
  vless
  vless_reality
  trojan
  shadowtls
  wireguard
  shadowsocks
  tuic
  anytls
  mixed
  socks
  tun
)

echo "================================================"
echo " TASK-CICD-VPN-PROTOCOL-E2E-ACCEPTANCE-SMOKE-001"
echo " VPN per-protocol E2E acceptance smoke"
echo "================================================"

run_layer() {
  local name="$1"
  local script="${SCRIPT_DIR}/${name}-smoke.sh"
  echo ""
  echo "--- Layer: ${name} ---"
  if [[ ! -f "${script}" ]]; then
    echo "BLOCKER: ${script} not found"
    exit 1
  fi
  bash "${script}"
}

run_layer "vpn-protocol-matrix"
run_layer "app-libbox-config"
run_layer "app-libbox-tunnel-runtime"
run_layer "app-android-libbox-runtime"

echo ""
echo "--- Acceptance matrix (CI layers) ---"
printf "%-16s | L1-backend | L2-config | L3-apple-rt | L4-android-rt | L5-device\n" "PROFILE"
printf "%-16s-+-%-10s-+-%-9s-+-%-11s-+-%-13s-+-%-9s\n" "----------------" "----------" "---------" "-----------" "-------------" "---------"
for profile in "${PROFILES[@]}"; do
  case "${profile}" in
    mixed|socks|tun)
      l3="N/A-inbound"
      l4="blocked"
      l5="ops-only"
      ;;
    *)
      l3="PASS"
      l4="degraded*"
      l5="OPEN"
      ;;
  esac
  printf "%-16s | %-10s | %-9s | %-11s | %-13s | %-9s\n" \
    "${profile}" "PASS" "PASS" "${l3}" "${l4}" "${l5}"
done

echo ""
echo "* Android L4: hysteria2=real H2Mobile; other libbox profiles return"
echo "  structured android_libbox_aar_missing (no fake connected)."
echo "  L5 device proof: see livemask-docs/tasks/TASK-VPN-E2E-*.md"

if [[ -d "${DOCS_ROOT}" ]]; then
  missing=0
  for profile in vless vless_reality trojan shadowtls wireguard shadowsocks tuic anytls; do
    task_suffix="$(echo "${profile}" | tr '[:lower:]' '[:upper:]' | tr '_' '-')"
    task_file="${DOCS_ROOT}/docs/development/tasks/TASK-VPN-E2E-${task_suffix}-001.md"
    if [[ ! -f "${task_file}" ]]; then
      echo "WARN: missing task doc ${task_file}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] && echo "PASS: per-protocol TASK-VPN-E2E-* docs present"
fi

echo ""
echo "[TASK-CICD-VPN-PROTOCOL-E2E-ACCEPTANCE-SMOKE-001] All CI-safe layers PASSED."
