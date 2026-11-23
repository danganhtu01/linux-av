OC-T-0139: empty effective Surface ExecStartPre repair over
`e346f57c194bebba398b340ae99fe6dfc7699f9b` (2026-11-23 UTC).

No worker commit, push, card, approval request, elevation, chroot, host install,
live service action, actual scanner execution or historical cache-file access.
All executed tests run as uid 10002 in the supplied build sandbox.

The exact historical base commands remain data only:

```text
ExecStart=/home/atdang/.cache/os-config/repos/danganhtu01/linux-av/bin/av-scan --now
ExecStart=/home/atdang/.cache/os-config/repos/danganhtu01/linux-av/bin/av-scan --rootkit
```

Acceptance still requires the default corresponding service, exactly one base
ExecStart in [Service], a safe loaded root-owned.conf containing exactly an empty
ExecStart reset and the matching permanent av-scan command, the exact loaded
base fragment, NeedDaemonReload=no, and root identity (including default empty
User/Group; no DynamicUser). Ownership/type/mode/ancestor and effective input
path audits remain unchanged. No checkout path is inspected, resolved, sourced
or executed, and the historical path allowlist has not expanded.

The one changed legacy acceptance condition permits explicit `ExecStartPre=`
readback, alongside the previously supported single permanent av-guard command
with ignore_errors=no. Unknown commands, duplicate guards, wrong arguments,
ignored failures, malformed or missing property readback still refuse. Final
policy readback uses the same explicit-empty condition, rather than a second
--value read that could treat malformed output as absence. av-root and av-guard
are unchanged: av-root itself checks av-guard --power before privileged Bash or
any toolkit library/config. No pre-start hooks are added.

Both unprivileged and root fixtures now cover unguarded and guarded layouts for
both exact base units, with matching root-owned.conf resets. The unprivileged
fixture uses default root identity, retains byte-exact non-command settings and
all four original backups, proves actual failed-install retry without manually
clearing power.incomplete, and proves byte-stable repeat installation. It checks
installed guard success and the real read-only av-setup power-policy-verify CLI,
including unchanged bytes/metadata and no service mutations on success or
negative effective readback. Historical missing-guard refusal is now the required
unguarded positive; all other old negatives remain. Added negatives cover
unexpected base hooks, accumulated duplicate guards, blank/malformed readback,
Group and DynamicUser. Each layout has 70 preflight negatives (140 total).

The shared inert systemctl fixture now emits explicit empty Exec properties and
accumulates and resets ExecStartPre entries as systemd does; it no longer hides earlier
hooks by returning only the last one. The shared installer harness now delegates
verification to the real read-only CLI, including its stderr-only errors. Its
private relocated copies still recompute test-only pins; production has no test
bypass. tests/policy.sh also uses an inert scan stand-in to demonstrate that
av-root prints av-guard: ok before forwarding each intended argument, and refuses
unsafe tool permissions before reaching the stand-in. No actual scanner runs.
The root fixture is syntax checked only: it is not executed because chroot is
excluded from this task. It retains all prior checks, runs both layouts, and adds
failed-install retry and original-backup/no-added-hook checks. Its copied OS-tool
list now includes find/diff already used by its snapshot assertions.

Evidence and limitations

- RED: archive of exact e346f57 production sources, with only the final Surface
  test and shared fixture scripts copied in, exits 1 on the unguarded retry:
  `unexpected effective Surface guard for linux-av-scan: ExecStartPre=`.
  Log: `/lane/tmp/oc-t-0139-empty-pre-red.log`.
- `timeout 180 bash tests/policy.sh`: exit 0. Includes both scan arguments
  through the launcher's own guard, installed/effective policy success, malformed
  and unknown pre-start readback, intended arguments and unchanged refusal state.
  Log: `/lane/tmp/oc-t-0139-empty-pre-policy.log`.
- `timeout 240 bash tests/cron-migration.sh`: exit 0. Existing disable/drain,
  bounded timeout/recovery, old/open-inode jobs, stable repeat and policy-only
  checks pass. Log: `/lane/tmp/oc-t-0139-empty-pre-cron.log`.
- GREEN: `TMPDIR=/tmp timeout 600 bash tests/surface-migration.sh`: exit 0.
  Both exact unguarded and guarded layouts pass migration, incomplete-install
  retry, settings/backups, repeat, installed guard, read-only policy verification
  and all 140 preflight negatives. Log: `/lane/tmp/oc-t-0139-empty-pre-green.log`.
  The first standalone run reached its old 240-second bound during the expanded
  guarded checks; it is superseded by this complete run.
- `timeout 900 bash tests/run.sh`: exit 0; **235 passed, 0 failed,
  37 skipped (need root)**. This includes the expanded Surface fixture, policy,
  cron migration and existing runtime checks.
  Log: `/lane/tmp/oc-t-0139-empty-pre-tests.log`.
- `timeout 900 bash tests/mutants.sh power_surface_empty_rejected
  power_surface_base_shape_removed power_surface_reset_removed
  power_surface_guard_removed power_scan_pre_readback_removed
  power_scan_intended_readback_removed`: exit 0; clean baseline **2 passed,
  0 failed**; **6 killed, 0 survived**. These cover empty legacy acceptance,
  exact base/reset shape, unexpected pre-start refusal, final pre-start readback
  and intended scan/rootkit argument readback.
  Log: `/lane/tmp/oc-t-0139-empty-pre-mutants.log`.
- Independent production digest verification: power 13/13, guard 1/1, OVH 3/3.
  Only the power installer's lib/root-policy.sh pin changes. The helper/release
  gate must independently pin the installer itself.
- bash -n passes for lib/root-policy.sh and the Surface, shared fixture, policy,
  root-power, run, cron-migration and mutants scripts; /bin/sh -n passes for the
  power installer. git diff --check passes.

Final SHA-256 source digests:

```text
d292af0b543e7a0f4a08b8a5854662d9924c56e155342f2af4e6169472326364  root-install-power.sh
c5ab3280211ceabcbbe2bacd6cab0625a6c3a684b74a51db252df57dfd592aa7  lib/root-policy.sh
20a73f712d58be113db050b53281c9124d22a8bf9f7d895818f644e3f24286b9  bin/av-guard
febff35d3765fd8c4b29d6f09d2f88e7c8013cdaa6765c341e626b33a21f3b14  bin/av-root
f2095e683937b0d661eef6569f5a989e41125583771fdb2ac1cf7ec83a59fde3  tests/surface-migration.sh
14580238a89dbd2741de7486628cf6ab77e26a39c9d672d246674120977ada85  tests/fixtures/power-install-env.sh
825e99125f9bb272a9a23f27fc68fc8baeab4466f2ee801ead54750afa065a08  tests/fixtures/policy-systemctl
17c80560f13f1d9e559743260e80de414e5fdd9c225afd7ba63d25d07ac46068  tests/root-power.sh
a01992470bf04ea3737bfb157a5dbe51c95062c19acb210e3a80d280555dbd89  tests/policy.sh
0cfa8a7fc55c6ef898dbee0ca079127805f7e8b2fd83ec7a4991e8d913425026  tests/mutants.sh
```

These are local unprivileged synthetic results. Root/chroot and remote Surface
execution remain unperformed. Real root ownership, host proc visibility, actual
systemd readback and crash/power-cut durability are not established by these
fixtures. The existing dispatcher census and supported-layout limitations remain.
The user-supplied real Surface readback is task evidence, not a live observation
made during this repair. No deployment or activation is performed. Work completed within the requested
30-minute limit.
