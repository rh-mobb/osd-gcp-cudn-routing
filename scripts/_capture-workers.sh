#!/usr/bin/env bash
# Temporary helper: parallel worker captures + curl test + pcap extraction.
# Run from repo root.  NOT committed — delete after use.
# Usage: bash scripts/_capture-workers.sh

OUTDIR="$(cd "$(dirname "$0")/.." && pwd)/references/pcap-2026-04-23"
CLUSTER_DIR="$(cd "$(dirname "$0")/.." && pwd)/cluster_bgp_routing"
VIRT_SSH="$(cd "$(dirname "$0")" && pwd)/virt-ssh.sh"

echo "=== OUTDIR:      $OUTDIR ==="
echo "=== CLUSTER_DIR: $CLUSTER_DIR ==="

# Node list in "full-hostname short-label" format
CAPTURE_NODES=(
  "cz-demo1-k5r7v-baremetal-a-l6z4w.c.mobb-demo.internal l6z4w"   # VM's own node
  "cz-demo1-k5r7v-baremetal-a-wnl8v.c.mobb-demo.internal wnl8v"
  "cz-demo1-k5r7v-worker-a-6zhtm.c.mobb-demo.internal    6zhtm"
  "cz-demo1-k5r7v-worker-b-dbdpm.c.mobb-demo.internal    dbdpm"
  "cz-demo1-k5r7v-worker-c-82fzn.c.mobb-demo.internal    82fzn"
)

PIDS=()

# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 1: start captures on all 5 workers ==="
# oc debug node runs as privileged with hostNetwork=true: the container sees
# br-ex in the host network namespace.  Write pcap to /host/var/tmp so the
# file persists on the real node FS after the pod exits.
for entry in "${CAPTURE_NODES[@]}"; do
  node="${entry%% *}"
  short="${entry##* }"
  echo "  Starting capture on $short ..."
  oc debug node/"$node" --quiet -- \
    /bin/bash -c \
    "tcpdump -nn -i br-ex dst host 10.100.0.7 -w /host/var/tmp/worker-pcap-${short}.pcap \
     2>/host/var/tmp/worker-pcap-${short}.log" &
  PIDS+=($!)
  echo "    PID $! for $short"
done

echo ""
echo "Sleeping 30 s for debug pods to start and tcpdump to begin listening..."
sleep 30

# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 2: run 50-curl internet test from virt-e2e-bridge ==="
CURL_RESULT=$(
  bash "$VIRT_SSH" -C "$CLUSTER_DIR" virt-e2e-bridge -- \
    'for i in $(seq 1 50); do curl -4s --max-time 3 -o /dev/null -w "%{http_code}\n" https://ifconfig.me; done | sort | uniq -c' \
    2>/dev/null
)
echo "Result:"
echo "$CURL_RESULT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 3: stop captures ==="
for pid in "${PIDS[@]}"; do
  kill -TERM "$pid" 2>/dev/null \
    && echo "  Terminated PID $pid" \
    || echo "  PID $pid already exited"
done
echo "Waiting 8 s for pods to finalise pcap files..."
sleep 8

# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 4: extract pcaps from each node ==="
for entry in "${CAPTURE_NODES[@]}"; do
  node="${entry%% *}"
  short="${entry##* }"
  outfile="$OUTDIR/worker-pcap-${short}.pcap"
  logfile="$OUTDIR/worker-pcap-${short}.log"
  echo ""
  echo "  [$short] extracting pcap → $outfile ..."
  # Use tar | tar pipeline to handle binary safely through oc exec stdout.
  oc debug node/"$node" --quiet -- \
    chroot /host tar -cf - -C /var/tmp "worker-pcap-${short}.pcap" 2>/dev/null \
    | tar -xOf - "worker-pcap-${short}.pcap" > "$outfile"
  # Also fetch the tcpdump stderr log (packet counts, errors).
  oc debug node/"$node" --quiet -- \
    chroot /host cat "/var/tmp/worker-pcap-${short}.log" 2>/dev/null \
    > "$logfile" || true
  echo "  [$short] pcap: $(ls -lh "$outfile" 2>/dev/null | awk '{print $5, $9}')"
  echo "  [$short] log:  $(cat "$logfile" 2>/dev/null || echo '(empty)')"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Done ==="
echo ""
echo "Curl result summary:"
echo "$CURL_RESULT"
echo ""
ls -lh "$OUTDIR"/worker-pcap-*.pcap 2>/dev/null || echo "(no pcaps found)"
