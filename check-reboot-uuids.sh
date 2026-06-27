#!/bin/bash
# Run this ONCE after rebooting (from the repo root) to verify space uuid
# stability across reboot — the last unverified Phase-0 assumption (TODO.md).
cd "$(dirname "$0")"
swift build 2>/dev/null
.build/debug/SpikeSpaces --dump 2>/dev/null | grep 'User spaces' \
  | grep -oE 'uuid=[0-9A-F-]{36}' | sed 's/uuid=//' | sort > /tmp/reboot-uuids-after.txt
echo "=== before (pre-reboot) vs after (post-reboot) user-space uuids ==="
if diff -q reboot-uuid-baseline.txt /tmp/reboot-uuids-after.txt >/dev/null; then
  echo "✅ STABLE — every user-space uuid survived the reboot. uuid is a reboot-safe key."
else
  echo "⚠️  uuids CHANGED across reboot. Persisted-uuid resolution would miss; the"
  echo "    (display, ordinal) fallback carries it. Details:"
  diff reboot-uuid-baseline.txt /tmp/reboot-uuids-after.txt
fi
