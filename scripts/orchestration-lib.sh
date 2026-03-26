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
