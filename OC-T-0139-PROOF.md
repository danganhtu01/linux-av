OC-T-0139 follow-up over `977fc1b` (`tasks/av-legacy-verified`). No worker commit, push, host installation, chroot, elevation, host service action or new card was performed.

The supplied isolated root-power result was 1/6 checkpoints passed, with the active-cron repeat failing its installed-byte/backups comparison at line 52 and four checkpoints unreached. That root proof was not rerun here.

Reproduction and exact change:

- The unprivileged migration fixture now uses the root launcher's log destination, relocated to its private `/var/log/linux-av`, instead of hiding the log outside the installed-tree snapshot. It also seeds the supported existing service commands, override, guard and resource limits used by root-power.
- Before the production fix, the same `find usr/local/lib/linux-av etc var -type f -print0 | sort -z | xargs -0 sha256sum` assertion failed after the second successful installation. The diff named exactly **`var/log/linux-av/av-scan.log`** (line 59 in the initial four-cron fixture). Its digest changed from `d1fd1a9a287b5f2982a70fe4cf4faad2f33ccaa8c1e93631333785ebd8880dfc` to `964be7fa5a7a8112911176a39022cc84269505eba01c255b034f3f7a1485f099`.
- The final `log_info` in `av_power_policy` appended timestamped installation status to the scan log on every success. It now prints the same status meaning to stderr with `printf`. Error logging, installation ordering, locks, drain, durable archives, effective-policy readback and guarded activation are unchanged.
- Generated `power.release.sha256` and `power.cron.sha256`, original backups and migration archives were byte-stable in that reproduction. No paths are excluded from either snapshot. The regression independently compares the release manifest with the private installer's pins and cron manifest with the four preserved originals. It includes pre-existing scan history and checks all pending markers and transient `open.wrapper.*` links are absent after success; raw retained inodes and archives remain included.
- Root-power's byte and metadata comparison failures now print unified diffs naming changed, added or removed paths. A function-only unprivileged check confirmed identical snapshots pass and a changed scan-log digest fails with its pathname in the diagnostic. The root fixture itself was not executed.
- `power_policy_install_logs` restores the old logging call to ensure the regression rejects it. Existing disable/drain/readback-order mutations remain selected for validation.

Execution environment: uid `10002`, hostname `6598f8521884`, supplied build sandbox, 2026-11-22 UTC. `getent hosts corsair` failed and no SSH configuration/connection was supplied. These results are local unprivileged proofs, **not a corsair-host test run**. The requested corsair run remains unavailable without a connection. The fixtures simulate root identity/ownership only in private copies, retain real bytes/types/modes, use inert systemctl and only fixture processes in their proc inventory, and shorten polling only in test copies. Production has no fixture or security bypass switch.

Validation:

- `timeout 300 bash tests/run.sh`: 234 passed, 0 failed, 37 skipped (need root). Full log: `/lane/tmp/oc-t-0139-tests.log`.

- `timeout 150 bash tests/cron-migration.sh`: passed the complete final fixture, including byte/backups stability with cron active, independent manifests, timeout/recovery, open-inode and older-launcher drain, policy-only refresh, unsafe entry refusals and no service actions.
- `timeout 240 bash tests/mutants.sh power_policy_install_logs power_cron_disable_removed power_cron_wait_removed power_cron_publish_before_readback`: clean baseline **1 passed, 0 failed**; **4 killed, 0 survived**.
- Individual `bash -n` checks passed for `lib/root-policy.sh`, `tests/cron-migration.sh`, `tests/root-power.sh`, `tests/mutants.sh`, and `tests/run.sh`; `/bin/sh -n root-install-power.sh` passed.
- Independently recomputed installer pins: power **13/13**, guard **1/1**, OVH **3/3** match. Only the power installer's `lib/root-policy.sh` pin changed. `git diff --check` passed.

Final source SHA-256 fingerprints (independent installer provenance remains the release gate's responsibility):

```text
765e9f00e87c2dcadc7971c1139e59d1198008a7858b5d22a34528d119d6bd14  root-install-power.sh
4d8d04254d7c4ca2cca804521e217d22e41194ae76b6f3b69acd3f7d2a7525ca  lib/root-policy.sh
20a73f712d58be113db050b53281c9124d22a8bf9f7d895818f644e3f24286b9  bin/av-guard (unchanged)
```

Real root ownership, complete host proc access, actual systemd readback, storage/power-cut durability and the remaining isolated root checkpoints are not established by these unprivileged tests. Existing dispatcher census limitations and supported-layout requirements in README still apply.
