OC-T-0139 Surface follow-up over linux-av main `20f109b`.

No worker commit, push, approval request, chroot, elevation, host installation,
live service action or scanner execution was performed.

The exact Surface base commands are now accepted as historical unit-file data:

```text
ExecStart=/home/atdang/.cache/os-config/repos/danganhtu01/linux-av/bin/av-scan --now
ExecStart=/home/atdang/.cache/os-config/repos/danganhtu01/linux-av/bin/av-scan --rootkit
```

Acceptance requires the default scan/rootkit unit, exactly one base ExecStart in
the Service section, and a safe, loaded `root-owned.conf` containing exactly an
empty ExecStart reset followed by `/usr/local/lib/linux-av/bin/av-scan` with the
matching intended argument. The loaded fragment must be the expected base;
effective ExecStart and ExecStartPre must select that permanent command and the
exact permanent av-guard, without ignored errors. Loaded state must be fresh and
the effective identity must be root. Existing ownership/type/mode/ancestor and
effective systemd-input audits remain required. The writable checkout target is
never inspected, resolved, sourced or executed. Its spelling is compared as
data, not used to discover or authenticate executable bytes.

Only accepted ExecStart lines become `/bin/sh
/usr/local/lib/linux-av/bin/av-root av-scan --now` or `--rootkit`. Resets,
comments, environment, identity, install settings, Nice, timeouts, guards and
CPU/memory limits remain unchanged. Original backups remain intact. Unknown
commands, different checkouts, shell wrappers/modifiers, extra/wrong arguments,
malformed executable syntax and unsafe unit paths refuse. Final effective
readback also requires the exact intended argument for each migrated service.

The new `tests/surface-migration.sh` uses both exact Surface bases, both reset
overrides, both guards and retained settings. Its first installer attempt fails
effective guard readback after permanent code and `power.incomplete` have been
written. Correcting that readback and retrying succeeds without manually
clearing the marker. The marker disappears only after policy verification.
The fixture compares each migrated file against an independently rendered
expected file, compares all four original backups, checks unchanged guards and
limits, and compares the entire installed code/etc/var file snapshot on repeat.
It runs installed av-guard and installed/effective policy verification too.

There are 30 negative cases per service (60 total): missing/reset/duplicate or
misplaced directives, indentation and continuation, another checkout, shell or
command prefixes, mismatched/extra arguments, unknown executables and environment
inputs, absent/overridden guards or commands, ignored errors, stale readback,
wrong fragment/unloaded override, foreign/writable units and overrides, writable
parents, links and nonroot identity. Each must refuse before daemon-reload or
unit/backups changes, preserving the incomplete gate. Byte, type, mode,
ownership and link snapshots check refusal state. Test-only stat/readlink
tripwires also reject any attempt to inspect the historical checkout target.

The existing cron fixture shares its private installer harness with this test.
The harness relocates fixed installation/proc paths, simulates root ownership
and identity, supplies inert systemctl, and shortens drain polling only in test
copies. Production has no fixture/security bypass option. Installer pins for
these explicitly modified test copies are recomputed in private staging; the
production pins are checked independently below. `tests/policy.sh` additionally
proves read-only refusal for swapped effective scan/rootkit arguments. The
isolated root fixture now has both Surface bases, reset overrides and guards;
it was syntax checked and **not executed**.

Red/green evidence, run unprivileged on 2026-11-22 UTC:

- Archived production sources from `20f109b`, with only the current tests copied
  into that archive, fail the final exact Surface fixture on the retry:
  `unsupported executable ... ExecStart=/home/atdang/.cache/os-config/repos/danganhtu01/linux-av/bin/av-scan --now`.
  Log: `/lane/tmp/oc-t-0139-surface-red.log`.
- `timeout 240 bash tests/surface-migration.sh`: exit 0; migration, actual
  failed-install retry, byte-stable repeat, installed guard/policy and all 60
  negatives pass. Log: `/lane/tmp/oc-t-0139-surface-green.log`.
- `timeout 180 bash tests/policy.sh`: exit 0; read-only byte/metadata, effective
  policy, guard, command/argument and incomplete-marker checks pass.
  Log: `/lane/tmp/oc-t-0139-policy.log`.
- `timeout 180 bash tests/cron-migration.sh`: exit 0; existing disable/drain,
  timeout/recovery, old/open-inode jobs, repeat and policy-only checks pass.
  Log: `/lane/tmp/oc-t-0139-cron.log`.
- `timeout 600 bash tests/run.sh`: **235 passed, 0 failed, 37 skipped (need root)**.
  Log: `/lane/tmp/oc-t-0139-tests.log`.
- `timeout 900 bash tests/mutants.sh power_surface_base_shape_removed power_surface_reset_removed power_surface_guard_removed power_scan_intended_readback_removed`:
  clean baseline **2 passed, 0 failed**; **4 killed, 0 survived**.
  Log: `/lane/tmp/oc-t-0139-surface-mutants.log`.
- Individual `bash -n` checks passed for lib/root-policy.sh, the Surface/shared
  fixture scripts, policy, cron-migration, root-power, run and mutants scripts.
  `/bin/sh -n root-install-power.sh` and `git diff --check` passed.
- Independent production input digests match every installer pin: power
  **13/13**, guard **1/1**, OVH **3/3**. Only the power installer's root-policy pin
  changed. Independent installer provenance remains the release gate's job.

Final SHA-256 source digests:

```text
bf7e5c7ee534dc104ed9e35e332f522f8a04ecbcfa10392465038a580d87b509  root-install-power.sh
693c2fa22fb4b60621114b69be5ea69ce07f561981ae92999feabbbcaa84b6ee  lib/root-policy.sh
20a73f712d58be113db050b53281c9124d22a8bf9f7d895818f644e3f24286b9  bin/av-guard (unchanged)
febff35d3765fd8c4b29d6f09d2f88e7c8013cdaa6765c341e626b33a21f3b14  bin/av-root (unchanged)
6b86353416bd4f827d0c5e6345805d90060824dc4a13f50a77ad737316c4675e  tests/surface-migration.sh
e19c707b8206de86758ebd54fce5e33e3b540320c318e0e190743a7d728103da  tests/fixtures/power-install-env.sh
f9762f800c732dcebbdad9ed3d59b6380169ed1a1b2ae46e5b513875e9fdc912  tests/root-power.sh
```

Execution identity was uid **10002**, hostname **d3c6dfc6192c**, supplied build
sandbox. Neither `getent passwd corsair` nor `getent hosts corsair` returned an
entry, and no SSH connection/configuration was supplied. These are local
unprivileged results; a corsair run remains unperformed. Real root ownership,
host proc visibility, actual systemd readback and crash/power-cut durability are
not established by the synthetic fixtures. The existing dispatcher census and
supported-layout limitations still apply.
