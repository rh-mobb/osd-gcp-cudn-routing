#!/usr/bin/env bash
# Apply netshoot-cudn and icanhazip-cudn in the CUDN namespace (default: cudn1).
# Shared by ILB and BGP stacks. Requires oc and a logged-in cluster.
set -euo pipefail

NAMESPACE="${CUDN_NAMESPACE:-cudn1}"
WAIT_TIMEOUT="${CUDN_TEST_PODS_WAIT_TIMEOUT:-120s}"
DO_WAIT=1
DO_IP_ADDR=1
# Delete test pods before apply (only when needed: pod spec is immutable; routine e2e avoids churn).
RECREATE_TEST_PODS=0

usage() {
  echo "Deploy netshoot-cudn and icanhazip-cudn for CUDN connectivity tests."
  echo "Usage: $(basename "$0") [options]"
  echo "  -n, --namespace NS   Namespace (default: cudn1 or CUDN_NAMESPACE)"
  echo "      --timeout DUR    oc wait timeout (default: 120s or CUDN_TEST_PODS_WAIT_TIMEOUT)"
  echo "      --recreate-test-pods  Delete netshoot-cudn / icanhazip-cudn first (use once if pod spec must change)"
  echo "      --no-wait        Apply only; do not oc wait or ip addr"
  echo "  -h, --help           This help"
  echo "Env: CUDN_TEST_PODS_RECREATE=1|true same as --recreate-test-pods"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -n | --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --timeout)
      WAIT_TIMEOUT="$2"
      shift 2
      ;;
    --recreate-test-pods)
      RECREATE_TEST_PODS=1
      shift
      ;;
    --no-wait)
      DO_WAIT=0
      DO_IP_ADDR=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "${CUDN_TEST_PODS_RECREATE:-}" in
  1 | true | True | yes | YES) RECREATE_TEST_PODS=1 ;;
esac

command -v oc >/dev/null 2>&1 || {
  echo "Error: oc not found on PATH." >&2
  exit 1
}

if [[ "$RECREATE_TEST_PODS" -eq 1 ]]; then
  echo "Recreating test pods (--recreate-test-pods / CUDN_TEST_PODS_RECREATE)."
  oc delete pod -n "$NAMESPACE" netshoot-cudn icanhazip-cudn --ignore-not-found --wait=true --timeout=120s
fi

oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: netshoot-cudn
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: netshoot
    image: nicolaka/netshoot
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
  restartPolicy: Never
---
apiVersion: v1
kind: Pod
metadata:
  name: icanhazip-cudn
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: icanhazip
    image: docker.io/thejordanprice/icanhazip-clone:latest
    # Upstream CMD runs app.py with port=80 baked in; use Flask CLI instead (no image fork).
    workingDir: /app
    env:
    command: ["/bin/sh", "-c", "exec python -m flask run --host=0.0.0.0 --port=8080"]
    ports:
    - containerPort: 8080
  restartPolicy: Never
EOF

if [[ "$DO_WAIT" -eq 1 ]]; then
  oc wait --for=condition=Ready pod/netshoot-cudn pod/icanhazip-cudn -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT"
  echo "Ready: netshoot-cudn, icanhazip-cudn (namespace=${NAMESPACE})"
fi

if [[ "$DO_IP_ADDR" -eq 1 ]]; then
  oc exec -n "$NAMESPACE" netshoot-cudn -- ip addr
fi
