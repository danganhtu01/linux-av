OC-T-0139: absent ExecStartPre stdout, source-only build (2026-11-23 UTC).

Fresh task: accept absent-property output at both root-policy stages.
Branch: `codex/build/oc-t-0139-absent-pre-20261123`.
Base: `8041abf941f21ded35255d6c33e59a1530c7ad45`.

Both the legacy Surface preflight and final installed-policy readback now accept
successful empty stdout as equivalent to explicit `ExecStartPre=`. The existing
single permanent av-guard command with ignore_errors=no remains accepted.
Nonempty responses still enter the existing exact parsed-command comparison;
nonmatching parsed responses refuse. A failing systemctl call still refuses
before either acceptance condition. No fallback query or whitespace trimming was
introduced. All other production policy and launcher checks are unchanged.

Only lib/root-policy.sh and its root-install-power.sh SHA-256 pin change in
production. The installer still has 13 pinned inputs. Its externally verified
installer digest must use the new value below.

Inert fixture changes

- Empty override files in the existing private systemctl fixture supply healthy
  empty stdout for both unguarded Surface services through incomplete-install
  retry, repeat installation and policy verification. Overrides are output data;
  no new command is executed from them. The shared systemctl stub is unchanged.
- Surface read-only verification explicitly accepts both empty stdout and
  `ExecStartPre=` for each service in each layout. tests/policy.sh also accepts
  both forms independently for scan and rootkit, retaining its permanent-guard
  positive and read-only snapshots.
- The old empty-output negative is now a whitespace-only nonempty response in
  each readback-negative loop and in the preflight matrix (`whitespace_pre`).
  Empty output is intentionally positive; the whitespace response still refuses.
  The other 34 preflight defects remain unchanged. The matrix retains all 140
  rejection slots, including malformed data, unknown commands, duplicate guards,
  ignored failures, wrong arguments, identity, metadata and structural refusals.
- Four new mutants change one parser condition in one stage apiece: removing the
  nonempty check loses absent-property acceptance; replacing the condition with
  false loses nonmatching rejection. Each uses the existing inert output data.
  The existing combined empty-rejection mutant is updated to match the new
  condition. No mutation has been applied or executed during this task.

Exact static expectations for separate chief approval

These counts come from reading source definitions and loop cardinalities. They
are expected outcomes conditional on later successful execution, not run results.

| Source or future scoped selection | Exact static expectation |
| --- | --- |
| Surface preflight rejection matrix | 35 defects x 2 services x 2 layouts = **140 refusals**, 70 per layout |
| Surface explicit absent/empty positive loop | 2 forms x 2 services x 2 layouts = **8 successful read-only verifications** |
| Surface pre-start readback-negative loop | 4 responses x 2 services x 2 layouts = **16 refusals** |
| Policy explicit absent/empty positive loop | 2 forms x 2 services = **4 successful read-only verifications**, plus 2 permanent-guard positives |
| Policy pre-start readback-negative loop | 4 responses x 2 services = **8 refusals** |
| Two scoped rows: power_surface_migration, power_policy_verify | **2 passed, 0 failed, 0 skipped** as an unprivileged user |
| Four new mutants listed below | Clean baseline: **2 passed, 0 failed**; mutations: **4 killed, 0 survived, 0 skipped** as an unprivileged user |
| Existing six scoped mutants plus the four new ones | Clean baseline: **2 passed, 0 failed**; mutations: **10 killed, 0 survived, 0 skipped** as an unprivileged user |
| Full tests/run.sh source census | **272 rows**: 37 use guard_root_only; unprivileged healthy expectation **235 passed, 0 failed, 37 skipped** |
| tests/mutants.sh source census | **325 entries**, including 4 new entries; 75 guard_* entries require root |
| This task's execution | **0 tests, 0 syntax checks, 0 cases, 0 mutant runs** |

New scoped mutation names:

```text
power_surface_absent_rejected
power_scan_absent_rejected
power_surface_nonmatching_accepted
power_scan_nonmatching_accepted
```

Existing six scoped mutation names:

```text
power_surface_empty_rejected
power_surface_base_shape_removed
power_surface_reset_removed
power_surface_guard_removed
power_scan_pre_readback_removed
power_scan_intended_readback_removed
```

Source SHA-256 digests (computed by reading bytes only):

```text
d259c44bea50c53fe980acc26ef7f6a78846e3f07bbd15983e0153e545b52516  root-install-power.sh
8db19d6c2442cc7477d46e8b4fe1175e3bbda535cde26049781747f19b4b3c00  lib/root-policy.sh
d2491fe92abb966bf4b8b7e6806889efac108aba4a19ff70f41b5fa1cf682efd  tests/surface-migration.sh
a85d791d3be2ac352d90b6b67bb4d42964b64b48e0e72e092a824aa738806801  tests/policy.sh
fad215766f96c09f4a47a95800229fe6b7dfa0a4e33879d89b1587db64faf14f  tests/mutants.sh
```

No tests, syntax checks, suites, cases or mutants were run. No live service or
host command, chroot, installation, scanner, exploit reproduction, push, approval
request or worker commit was performed. Historical test results from the prior
proof do not establish this build. Actual execution and real systemd behavior
remain unverified here; separate chief approval is outside this task. COMMIT_MSG
is provided for the helper's import/commit hooks.
