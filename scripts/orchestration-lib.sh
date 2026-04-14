#!/usr/bin/env bash
# Shared helpers for ilb-apply.sh / bgp-apply.sh (sourced, not executed).
# shellcheck shell=bash

# Return 0 if terraform state lists at least one resource under module.<name>[0].
tf_state_counted_module_present() {
  local dir="$1"
  local module_base="$2"
  local out
  if ! out=$(cd "$dir" && terraform state list 2>/dev/null); then
    return 1
  fi
  grep -qE "^module\\.${module_base}\\[0\\]\\." <<<"$out"
}

# True when ORCHESTRATION_FORCE_PASS1 is 1/true (case-insensitive; Bash 3.2–safe).
orchestration_force_pass1() {
  local v
  v=$(printf '%s' "${ORCHESTRATION_FORCE_PASS1:-}" | tr '[:upper:]' '[:lower:]')
  [[ "${v}" == "1" || "${v}" == "true" ]]
}

# Poll until HTTPS to the API verifies with the system CA bundle (e.g. OSD/OCM
# replacing the bootstrap self-signed cert). Uses GET /version (no -f): TLS or
# transport errors keep polling; HTTP status is ignored as long as curl exits 0.
# Args: api_url (https://host:port). Optional: max_seconds (else OC_WAIT_API_TLS_MAX_SEC or 600).
orchestration_wait_api_tls() {
  local api_url="$1"
  local max_sec="${2:-${OC_WAIT_API_TLS_MAX_SEC:-600}}"
  local interval="${OC_WAIT_API_TLS_INTERVAL_SEC:-15}"
  local deadline
  deadline=$(($(date +%s) + max_sec))
  local base="${api_url%/}"
  local url="${base}/version"
  local rc

  echo "Waiting for API TLS to verify with system CAs (max ${max_sec}s, every ${interval}s; OC_WAIT_API_TLS_MAX_SEC / OC_WAIT_API_TLS_INTERVAL_SEC)..."
  while (( $(date +%s) < deadline )); do
    rc=0
    curl -sS -o /dev/null --connect-timeout 10 --max-time 25 "$url" || rc=$?
    if (( rc == 0 )); then
      echo "API TLS verified."
      return 0
    fi
    echo "  TLS/API not ready yet (curl exit ${rc}); sleeping ${interval}s..."
    sleep "$interval"
  done
  echo "Error: timed out after ${max_sec}s waiting for trusted API TLS (probed: ${url})." >&2
  echo "  To skip this wait, set OC_LOGIN_EXTRA_ARGS='--insecure-skip-tls-verify'." >&2
  return 1
}
