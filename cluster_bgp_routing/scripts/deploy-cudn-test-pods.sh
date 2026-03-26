#!/usr/bin/env bash
# Delegates to repo-wide script (shared with ILB stack).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$REPO_ROOT/scripts/deploy-cudn-test-pods.sh" "$@"
