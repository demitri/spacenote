# TODO

- [ ] **Verify space-uuid stability across reboot** (PLAN.md §7 fact (b) — the
  last unverified Phase 0 assumption). After the next reboot:

  ```sh
  cd $GH/spacenote && .build/debug/SpikeSpaces --dump
  ```

  and diff the per-space `uuid`s/ordinals against the baseline session in
  `spike-spaces.log` (the dumps from boot `2026-06-06T06:33:39Z`). If uuids
  are stable: done, delete this item. If they churn: the app already falls
  back to `(display, ordinal)` resolution, but confirm notes actually land on
  the right desktops after that reboot and consider promoting ordinals to the
  primary key.
