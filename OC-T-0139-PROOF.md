Candidate over partial `944727248b6247b11543a9b5a7d3c5338aebe937`, for a separate gate. HEAD is unchanged; no worker commit, amend, push, host installation, chroot, elevation, or host service action was performed.

Execution was in the supplied build sandbox, uid `10002`, hostname `d81d823dc7e8`, on 2026-11-22 UTC. A literal `corsair` host identity/connection was not available (`getent hosts corsair` failed; no SSH configuration was supplied). These are unprivileged sandbox proofs, not evidence of a separate run on the corsair host or its real cron daemon.

The candidate changes only migration/policy ordering, associated pins, fixtures and documentation. The installer and policy-only refresh hold the exclusive policy lock while they durably preserve originals, atomically disable all supported dispatch entries, drain recognizable legacy work, install policy, read it back, publish guarded routes, and durably clear the incomplete gate. Even canonical wrappers are disabled: their old launcher may lack the lock. Existing legitimate originals are retained independently of incoming package scripts. Raw archives preserve regular type, bytes, uid/gid and mode; working originals remain 0644.

The new executable fixture is `bash tests/cron-migration.sh`, also selected by `bash tests/run.sh power_cron_migration`. It executes private copies of the actual installer, disabler/drain and root policy renderer. It explicitly relocates fixed paths, simulates root metadata/identity, replaces service calls with the existing inert fixture, and shortens one-second polling sleeps to 0.02 seconds. It re-pins only those test copies. Production has no test-root, polling or identity switches. Its proc inventory intentionally contains only fixture processes plus synthetic PID 1.

The migration row asserts:

- An injected archive sync failure leaves the original dispatch and earlier original untouched and installs no code.
- All four daily entries are inert before a legacy FIFO reader can drain. While it remains alive, no installed tree appears; two bounded attempts time out plainly, without signaling it.
- Timeout preserves exact raw bytes, regular type and mode 0750, plus an earlier legitimate original of different bytes/mode 0600. Retrying a placeholder cannot reclassify it as an original. A missing working copy is restored from pending state.
- Failed effective-policy readback leaves dispatch inert and pending state intact. A later retry completes installation and guarded publication.
- A canonical route pointing to a simulated older launcher without a shared lock is disabled before waiting. Repeated inert dispatch opens succeed while the older process waits, then it is released naturally.
- A shell reading a legacy script through already-open fd 0, without an affected path in argv, is detected by the retained inode. Displaced code stays unchanged while it waits and is replaced after natural completion.
- Pending raw dispatch, placeholder without a working copy, and already-published wrapper with pending state recover. Orphan placeholders, symlink entries and directory entries refuse.
- Policy-only refresh disables/drains before replacing a policy sentinel, and publishes guarded routing afterward. No fixture service start/stop/restart/enable/disable/kill is permitted.

Checks executed:

- `bash tests/run.sh`: **234 passed, 0 failed, 37 root-only skips**. The skips are not passes. The earlier run before adding the migration row was 233/0/37.
- `bash tests/run.sh power_cron_migration power_policy_verify power_policy_install power_policy_exec_refused guard_install_hashes common_root_default`: **6 passed, 0 failed**.
- `bash tests/power.sh`: passed all supply/gating, unplug cancellation, scheduled/foreground reconnect, delegated daemon, packaged-cron and batteryless checks. All cancellation targets were inert fixture processes.
- `bash tests/policy.sh`: passed active-cron/quiescence/census, actual shared/exclusive lock, read-only installed-policy and mismatch checks.
- `bash tests/mutants.sh power_cron_disable_removed power_cron_wait_removed power_cron_publish_before_readback`: clean baseline; **3 killed, 0 survived**.
- `bash tests/mutants.sh power_cron_disable_removed power_cron_wait_removed power_cron_publish_before_readback power_verify_bytes_skipped power_verify_reload_ignored power_cron_lock_removed common_root_readonly_reassigned power_policy_exec_audit_removed power_policy_unterminated_exec_skipped`: final-source unmutated baseline **4 passed, 0 failed**; **9 killed, 0 survived**. This baseline also exercises the final archive verification changes after the full-suite/focused runs above.
- Individual `bash -n` checks: `lib/root-policy.sh`, `tests/cron-migration.sh`, `tests/policy.sh`, `tests/root-power.sh`, `tests/run.sh`, `tests/mutants.sh`. Individual `/bin/sh -n` checks: `bin/av-guard`, `root-install-power.sh`, `root-install-guard.sh`. All passed.
- Independently recomputed every header pin: power installer **13/13**, guard installer **1/1**, existing OVH installer **3/3** match. Only affected power/guard pins changed. `git diff --check` passed.

Candidate SHA-256 fingerprints (for gate comparison; independent installer provenance remains the gate's responsibility):

```text
578dcf232b96223781ab436dd53ed30e047f6f910b39c96f39f201a8eee423e9  root-install-power.sh
20a73f712d58be113db050b53281c9124d22a8bf9f7d895818f644e3f24286b9  bin/av-guard
b21ed871bb0b0aca302b98d55cac0372207e84831c00b4886658318a5b29b44f  lib/root-policy.sh
```

The wait has at most 60 censuses / 59 one-second sleeps and a 60-second worker deadline with two-second forced worker cleanup. Deadline signals target only the census worker group, never legacy jobs. The caller retains the exclusive lock. Timeout leaves dispatch disabled, durable originals and pending state retained, and the incomplete marker set; recovery is a retry after the jobs finish.

Limits remain explicit in README's dispatcher section. Rename cannot recall in-memory code. A census, even two clean passes, is not a kernel fork/exec barrier: hidden/renamed dispatchers, delayed unrecognized parents, aliases, copied code without recognizable argv/fds, or processes appearing after inspection can escape. Complete readable host proc/fd/exe access, a common filesystem for inode retention, standard run-parts naming that excludes dotted/hidden backup files, and no concurrent package/admin writes are preconditions. Arbitrary crontabs/cron.d routes, custom run-parts regexes, direct preserved-original execution and other listed external routes remain outside coverage. Such launchers require a separately controlled maintenance window. Visible run-parts/anacron/scanner names are conservative blockers.

The fixture tests state recovery and sync failure, not a real power cut. Durability follows checked copy/metadata/digest, file sync, atomic rename and parent-filesystem sync ordering; storage failure and real reboot behavior were not exercised. Real root ownership, a complete host proc census, supported host mount/unit layouts and actual systemd readback formats remain separate gate checks. The disposable root fixture was updated for drain timeout/new tool dependencies but deliberately not run.
