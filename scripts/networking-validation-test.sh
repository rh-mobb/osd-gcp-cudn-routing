#!/usr/bin/env bash
# Orchestrate CUDN networking validation: e2e-cudn-connectivity (+ optional second namespace),
# optional e2e-virt-live-migration, optional internet egress sampling from netshoot-cudn.
#
# Docs: docs/networking-validation-test-plan.md
# Default cluster dir: repo_root/cluster_bgp_routing (repo_root = parent of scripts/).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
E2E_CUDN="$SCRIPT_DIR/e2e-cudn-connectivity.sh"
E2E_VIRT="$SCRIPT_DIR/e2e-virt-live-migration.sh"

CLUSTER_DIR=""
NAMESPACE="${CUDN_NAMESPACE:-cudn1}"
ALSO_NAMESPACE=""
SKIP_CUDN=0
SKIP_VIRT=0
# Default: full virt (mesh, echo, migrations — e2e-virt-live-migration --run-tests). --virt-hints-only: access-only.
VIRT_HINTS_ONLY=0
INTERNET_PROBES=0
NETVAL_INTERNET_URL="${NETVAL_INTERNET_URL:-https://icanhazip.com}"

# Forwarded to e2e-cudn-connectivity.sh
CUDN_EXTRA=()
# Forwarded to e2e-virt-live-migration.sh (deploy / probe tuning)
VIRT_EXTRA=()

case "${NETVAL_VIRT_HINTS_ONLY:-}" in
  1 | true | True | yes | YES) VIRT_HINTS_ONLY=1 ;;
esac

init_term_colors() {
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
  local use=0
  if [[ "${FORCE_COLOR:-0}" == "1" || "${FORCE_COLOR:-}" == "yes" ]]; then
    use=1
  elif [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    use=1
  fi
  if [[ "$use" -eq 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
  fi
}

title() { printf '\n%s%s━━━ %s ━━━%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET" >&2; }
kv() { printf '  %s%-26s%s %s%s%s\n' "$C_CYAN" "$1" "$C_RESET" "$C_BOLD" "${2:-}" "$C_RESET" >&2; }
pass() { printf '%s%s[ PASS ]%s %s\n' "$C_GREEN" "$C_BOLD" "$C_RESET" "$1" >&2; }
warn() { printf '%s%s[ WARN ]%s %s\n' "$C_YELLOW" "$C_BOLD" "$C_RESET" "$1" >&2; }
fail() { printf '%s%s[ FAIL ]%s %s\n' "$C_RED" "$C_BOLD" "$C_RESET" "$1" >&2; }

usage() {
  cat <<EOF
Networking validation orchestrator (see docs/networking-validation-test-plan.md).

Runs e2e-cudn-connectivity.sh by default; virt e2e runs `e2e-virt-live-migration.sh --run-tests` (connectivity mesh, echo, migrations) unless --virt-hints-only.

Usage: $(basename "$0") [options]

  -C, --cluster-dir DIR   Terraform stack (default: REPO_ROOT/cluster_bgp_routing)
  -n, --namespace NS      Primary CUDN namespace (default: cudn1 or CUDN_NAMESPACE)
      --also-namespace NS  Also run CUDN e2e in NS (e.g. cudn2)
      --skip-cudn           Skip e2e-cudn-connectivity.sh
      --skip-virt           Skip e2e-virt-live-migration.sh
      --virt-hints-only     Virt: --skip-tests (VMs + console/virtctl only; no mesh, echo, or migrations)
      --virt-full           No-op; full tests are the default when this flag is not set; kept for compatibility
      --internet-probes N   After CUDN e2e, N curl attempts from netshoot-cudn (default 0 = off)
  Forwarded to e2e-cudn-connectivity.sh and e2e-virt-live-migration.sh:
      --allow-icmp-fail
      --recreate-test-pods
      --skip-deploy
      --timeout DUR
  -h, --help              This help

Env:
  NETVAL_INTERNET_URL       URL for --internet-probes (default https://icanhazip.com)
  NETVAL_VIRT_HINTS_ONLY=1  Same as --virt-hints-only
  CUDN_NAMESPACE            Default namespace if -n omitted

Examples:
  $(basename "$0") -C cluster_bgp_routing -n cudn1
  $(basename "$0") --also-namespace cudn2
  $(basename "$0") --virt-hints-only
  $(basename "$0") --internet-probes 30 --skip-virt

Exit 0 if all executed phases succeed; 1 otherwise.
EOF
}

validate_non_negative_int() {
  local name="$1" val="$2"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    fail "invalid $name (need non-negative integer): ${val:-empty}"
    exit 1
  fi
}

run_cudn_e2e() {
  local ns="$1"
  title "Phase A: CUDN pod e2e ($ns)"
  kv "script" "$E2E_CUDN"
  kv "cluster dir" "$CLUSTER_DIR"
  if [[ ${#CUDN_EXTRA[@]} -gt 0 ]]; then
    bash "$E2E_CUDN" -C "$CLUSTER_DIR" -n "$ns" "${CUDN_EXTRA[@]}"
  else
    bash "$E2E_CUDN" -C "$CLUSTER_DIR" -n "$ns"
  fi
  pass "CUDN e2e completed ($ns)"
}

run_internet_probes() {
  local ns="$1"
  local n="$2"
  title "Phase D: Internet egress sampling ($n probes, informational)"
  warn "Public internet from CUDN is often intermittent (ECMP + OVN-K). Do not gate routing health on this phase."
  kv "namespace" "$ns"
  kv "url" "$NETVAL_INTERNET_URL"
  if ! oc get pod -n "$ns" netshoot-cudn -o name >/dev/null 2>&1; then
    fail "netshoot-cudn not found in $ns (run CUDN e2e first)"
    return 1
  fi
  local ok=0 i
  for ((i = 1; i <= n; i++)); do
    if oc exec -n "$ns" netshoot-cudn -- timeout 25 curl -4 -fsS \
      --connect-timeout 10 --max-time 20 "$NETVAL_INTERNET_URL" -o /dev/null 2>/dev/null; then
      ok=$((ok + 1))
    fi
  done
  kv "success" "$ok / $n"
  pass "Internet probe phase finished (informational only; exit code always success if pod exists)"
  return 0
}

run_virt_e2e() {
  local ns="$1"
  title "Phase C: Virt e2e ($ns)"
  kv "script" "$E2E_VIRT"
  if [[ "$VIRT_HINTS_ONLY" -eq 1 ]]; then
    kv "mode" "hints only (--skip-tests)"
    if [[ ${#VIRT_EXTRA[@]} -gt 0 ]]; then
      bash "$E2E_VIRT" -C "$CLUSTER_DIR" -n "$ns" --skip-tests "${VIRT_EXTRA[@]}"
    else
      bash "$E2E_VIRT" -C "$CLUSTER_DIR" -n "$ns" --skip-tests
    fi
  else
    kv "mode" "full (--run-tests: mesh, echo, live migrations; same as VIRT_E2E_RUN_MIGRATIONS=1)"
    if [[ ${#VIRT_EXTRA[@]} -gt 0 ]]; then
      bash "$E2E_VIRT" -C "$CLUSTER_DIR" -n "$ns" --run-tests "${VIRT_EXTRA[@]}"
    else
      bash "$E2E_VIRT" -C "$CLUSTER_DIR" -n "$ns" --run-tests
    fi
  fi
  pass "Virt e2e completed ($ns)"
}

preflight() {
  title "Preflight"
  for bin in oc jq; do
    command -v "$bin" >/dev/null 2>&1 || {
      fail "$bin not found on PATH"
      exit 1
    }
  done
  if [[ "$SKIP_CUDN" -eq 0 ]]; then
    for bin in terraform gcloud; do
      command -v "$bin" >/dev/null 2>&1 || {
        fail "$bin not found on PATH (required for CUDN e2e)"
        exit 1
      }
    done
  fi
  if [[ "$SKIP_VIRT" -eq 0 && "$VIRT_HINTS_ONLY" -eq 0 ]]; then
    command -v terraform >/dev/null 2>&1 || {
      fail "terraform not found on PATH (required for full virt e2e: cudn_cidr / cudn-pod-ip.sh)"
      exit 1
    }
  fi
  if [[ "$SKIP_VIRT" -eq 0 ]]; then
    command -v ssh-keygen >/dev/null 2>&1 || {
      fail "ssh-keygen not found on PATH (required for virt e2e)"
      exit 1
    }
  fi
  pass "Required CLIs present for selected phases"
  if [[ ! -f "$E2E_CUDN" ]]; then
    fail "missing $E2E_CUDN"
    exit 1
  fi
  if [[ ! -f "$E2E_VIRT" ]]; then
    fail "missing $E2E_VIRT"
    exit 1
  fi
  CLUSTER_DIR="$(cd "$CLUSTER_DIR" && pwd)"
  if [[ ! -f "$CLUSTER_DIR/scripts/cudn-pod-ip.sh" ]]; then
    fail "expected $CLUSTER_DIR/scripts/cudn-pod-ip.sh (wrong --cluster-dir?)"
    exit 1
  fi
  kv "cluster dir" "$CLUSTER_DIR"
  pass "Cluster directory OK"
}

init_term_colors

while [[ $# -gt 0 ]]; do
  case $1 in
    -C | --cluster-dir)
      CLUSTER_DIR="$2"
      shift 2
      ;;
    -n | --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --also-namespace)
      ALSO_NAMESPACE="$2"
      shift 2
      ;;
    --skip-cudn)
      SKIP_CUDN=1
      shift
      ;;
    --skip-virt)
      SKIP_VIRT=1
      shift
      ;;
    --virt-hints-only)
      VIRT_HINTS_ONLY=1
      shift
      ;;
    --virt-full)
      VIRT_HINTS_ONLY=0
      shift
      ;;
    --internet-probes)
      INTERNET_PROBES="$2"
      shift 2
      ;;
    --allow-icmp-fail)
      CUDN_EXTRA+=(--allow-icmp-fail)
      VIRT_EXTRA+=(--allow-icmp-fail)
      shift
      ;;
    --recreate-test-pods)
      CUDN_EXTRA+=(--recreate-test-pods)
      VIRT_EXTRA+=(--recreate-test-pods)
      shift
      ;;
    --skip-deploy)
      CUDN_EXTRA+=(--skip-deploy)
      VIRT_EXTRA+=(--skip-deploy)
      shift
      ;;
    --timeout)
      CUDN_EXTRA+=(--timeout "$2")
      VIRT_EXTRA+=(--timeout "$2")
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CLUSTER_DIR" ]]; then
  CLUSTER_DIR="$REPO_ROOT/cluster_bgp_routing"
fi

validate_non_negative_int "--internet-probes" "$INTERNET_PROBES"

preflight

FAILURES=0

if [[ "$SKIP_CUDN" -eq 0 ]]; then
  run_cudn_e2e "$NAMESPACE" || FAILURES=$((FAILURES + 1))
  if [[ -n "$ALSO_NAMESPACE" ]]; then
    run_cudn_e2e "$ALSO_NAMESPACE" || FAILURES=$((FAILURES + 1))
  fi
else
  title "Phase A: CUDN pod e2e"
  warn "Skipped (--skip-cudn)"
fi

if [[ "$INTERNET_PROBES" -gt 0 ]]; then
  if [[ "$SKIP_CUDN" -ne 0 ]]; then
    warn "--internet-probes ignored (no CUDN e2e run; netshoot may be missing)"
  else
    run_internet_probes "$NAMESPACE" "$INTERNET_PROBES" || FAILURES=$((FAILURES + 1))
    if [[ -n "$ALSO_NAMESPACE" ]]; then
      run_internet_probes "$ALSO_NAMESPACE" "$INTERNET_PROBES" || FAILURES=$((FAILURES + 1))
    fi
  fi
fi

if [[ "$SKIP_VIRT" -eq 0 ]]; then
  run_virt_e2e "$NAMESPACE" || FAILURES=$((FAILURES + 1))
else
  title "Phase C: Virt e2e"
  warn "Skipped (--skip-virt)"
fi

title "Summary"
if [[ "$FAILURES" -eq 0 ]]; then
  pass "All executed phases succeeded"
  exit 0
fi
fail "$FAILURES phase(s) failed"
exit 1
