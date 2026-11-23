OC-T-0139: exact ExecStartPre stdout/status, source-only gate (2026-11-23 UTC).

Base: linux-av `2c3dd0817716ef8ed8bca612bcbd1da6e8b7edc1` (`2c3dd08`).
This follows the chief's new source gate described in the task: build and
source review only. No tests, syntax checks, cases or mutants are authorized or
run here. All execution expectations below are conditional, never run results.

Both query sites in lib/root-policy.sh (legacy Surface preflight and final
installed-policy readback) append the fixed `.OC-T-0139` sentinel only after
systemctl succeeds. Removing just that suffix preserves actual trailing LF
bytes. A failed query keeps its nonzero status through the assignment and takes
the same `cannot inspect` refusal, even with otherwise healthy stdout. No
fallback query, whitespace trimming or service action is added.

The exact empty-property acceptance set, at each site, is:

| stdout bytes | Accepted representation |
| --- | --- |
| zero bytes | `''` |
| `0a` | one LF |
| `45 78 65 63 53 74 61 72 74 50 72 65 3d` | `ExecStartPre=` without terminal LF |
| `45 78 65 63 53 74 61 72 74 50 72 65 3d 0a` | `ExecStartPre=` with one terminal LF |

All other responses still enter the existing permanent-guard parser/comparison.
That parser and its accepted exact path/argv/ignore_errors=no triple are
unchanged. The same nonmatching, wrong-command, duplicate-guard and ignored-error
refusals remain. Spaces, tabs, CR and multiple LFs cannot match either the empty
allowlist or the guard comparison. The existing av-root guard enforcement,
preflight no-write refusals and read-only verification snapshots remain intact.
Only lib/root-policy.sh and its root-install-power.sh pin change in production.
The installer still has 13 pinned inputs; its new external digest is below.

Four modified old preflight cases, individually identified

These are the four original `blank_pre` negative slots changed in 2c3dd08 to
`whitespace_pre`. This build preserves each replacement as a negative; it does
not claim an empty-output rejection survived. The original zero-byte input is
now independently positive at each stage/service/layout.

| Layout | Service | Old input / expectation | Retained input / expectation |
| --- | --- | --- | --- |
| unguarded | linux-av-scan.service | zero bytes / refusal | `20 0a` (space + LF) / refusal |
| unguarded | linux-av-rootkit.service | zero bytes / refusal | `20 0a` (space + LF) / refusal |
| guarded | linux-av-scan.service | zero bytes / refusal | `20 0a` (space + LF) / refusal |
| guarded | linux-av-rootkit.service | zero bytes / refusal | `20 0a` (space + LF) / refusal |

Inert fixture coverage and source-derived counts

The output files contain raw data and are copied with `cat`; no content is
executed. A property-specific marker now makes the systemctl stub exit 97 after
writing those bytes, without affecting earlier queries. Both sites must refuse
with policy exit 1 and their existing `cannot inspect` diagnostic when a query
fails with zero-byte or one-LF stdout. Successful controls use the same bytes.

The preflight matrix keeps the 35 existing defect names and adds eight raw-byte
defects plus two failed-query defects: 45 x 2 services x 2 layouts = 180 refusals
(90 per layout). Of these, 140 are the retained slots, 32 are added raw-byte
refusals and 8 are failed-query refusals. Its healthy loop adds 4 accepted forms
x 2 services x 2 layouts = 16 successful preflight installations. The original
guarded/unguarded retry, repeat, backups and preservation controls remain.

Each readback-negative loop now has 12 successful-query outputs: space (`20`),
tab (`09`), CR (`0d`), two LFs (`0a 0a`), space + LF (`20 0a`), tab + LF
(`09 0a`), CR + LF (`0d 0a`), three LFs (`0a 0a 0a`), `ExecStartPre=` plus
two LFs, garbage, the wrong command and the guard with ignore_errors=yes.
The nine byte-form negatives are shared with the preflight matrix, alongside
its existing malformed/wrong-command/ignored-error cases.

| Scoped fixture checks | Exact static counts |
| --- | --- |
| Surface final readback accepted empty forms | 4 forms x 2 services x 2 layouts = 16 successes |
| Surface final readback nonmatching outputs | 12 outputs x 2 services x 2 layouts = 48 refusals |
| Surface final readback failed empty/LF queries | 2 forms x 2 services x 2 layouts = 8 refusals |
| Policy final readback accepted empty forms | 4 forms x 2 services = 8 successes, plus 2 permanent-guard positives |
| Policy final readback nonmatching outputs | 12 outputs x 2 services = 24 refusals |
| Policy final readback failed empty/LF queries | 2 forms x 2 services = 4 refusals |
| Source census only (no full-suite proposal) | 272 row definitions; 327 mutants, including 75 root-only guard_* entries |
| This task's execution | 0 tests, 0 syntax checks, 0 cases, 0 mutant runs |

The two new `power_surface_whitespace_accepted` and
`power_scan_whitespace_accepted` mutants each replace one line's nonempty
predicate with `[[ $shown =~ [^[:space:]] ]]`, wrongly allowing arbitrary
whitespace through the empty branch. Healthy controls must pass first; the
space/tab/CR/multiple-LF negatives must kill the mutants. Existing absent and
nonmatching mutants remain scoped to their original stage. The combined
`power_surface_empty_rejected` pattern is adapted to the longer exact condition.
No mutant has been applied or executed during this task.

Exact proposed commands for a later, separately authorized unprivileged run

Run from the repository root as an already unprivileged user. These are proposals
only, not permission to execute now. There is no root, chroot, host or full-suite
command proposed for this gate. Require both the real exit status and complete
output. For EVERY command below, status 77, 64 or 70, or empty output, means
**NO-RESULT**; a missing expected baseline/summary also means NO-RESULT. Never
count a skipped, refused or absent run as a pass or a killed mutant.

1. `bash tests/run.sh power_surface_migration power_policy_verify`
   Expected exit: 0. Exact final summary: `2 passed, 0 failed`.
   Both named rows must be `ok`, with no skipped row.
2. `bash tests/mutants.sh power_surface_whitespace_accepted power_scan_whitespace_accepted`
   Expected exit: 0. Exact baseline: `unmutated: 2 passed, 0 failed`.
   Exact final summary: `2 killed, 0 survived`; no skipped mutant.
3. The following full scoped selection (12 entries):

   ```sh
   bash tests/mutants.sh \
     power_surface_empty_rejected \
     power_surface_base_shape_removed \
     power_surface_reset_removed \
     power_surface_guard_removed \
     power_scan_pre_readback_removed \
     power_scan_intended_readback_removed \
     power_surface_absent_rejected \
     power_scan_absent_rejected \
     power_surface_nonmatching_accepted \
     power_scan_nonmatching_accepted \
     power_surface_whitespace_accepted \
     power_scan_whitespace_accepted
   ```

   Expected exit: 0. Exact baseline: `unmutated: 2 passed, 0 failed`.
   Exact final summary: `12 killed, 0 survived`; no skipped mutant.

Source SHA-256 digests (computed by reading bytes only):

```text
e31d875f5ed6b4d0e815e1da8cf1e7072f814ea7a2d8544c3d83aefe66f452d6  root-install-power.sh
0d4686918073a3d0159a438306f2c0b84f690141e3926168b8fe169d55a7b5cf  lib/root-policy.sh
92fd1f8af8bdcc7587da9510503722fd6069088421525b845fda843accad7ec7  tests/surface-migration.sh
281b35b2f4033f8e51a395cbf9f103a0e8d528529dacac1297e8c66ea9160738  tests/policy.sh
6b06513e0a78a07e4298db0bf7163ffb9ae39a27f31c3f53662c2e8f12f71d8c  tests/fixtures/policy-systemctl
9d5906011df43ee284d637c9148868936de5b60c942c8b3c69da7f8d4ec9fd58  tests/mutants.sh
```

No tests, syntax checks, suites, cases, mutants, chroot, host installation or
service actions, push or worker commit were performed. Source inspection and
hashing do not establish runtime success or actual systemd output. Historical
results do not establish this build. COMMIT_MSG is supplied for the helper's
import/commit hooks; the helper's result remains authoritative.
