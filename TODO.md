# TODO

- [ ] **Verify space-uuid stability across reboot** (PLAN.md §7 fact (b) — the
  last unverified Phase-0 assumption). Baseline captured pre-reboot 2026-06-27 in
  `reboot-uuid-baseline.txt` (8 non-empty user-space uuids).

  **After your next reboot, run once from the repo root:**

  ```sh
  ./check-reboot-uuids.sh
  ```

  - ✅ prints "STABLE" → uuids survive reboot; `spaceUUID` is a reboot-safe key,
    nothing to change.
  - ⚠️ prints "CHANGED" → uuids churn across reboot; the `(display, ordinal)`
    fallback in `SpacesSnapshot.resolve` carries placement, but consider promoting
    the ordinal to the primary key. Paste the diff into a new session.

  (Within-session evidence so far: uuids are stable across weeks of desktop
  reordering — only ordinals shift. The reboot is the one case still untested.)
