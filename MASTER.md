# linux-av — MASTER

Cross-distro antivirus and host-protection toolkit for **Arch, Debian and Ubuntu**.
It is plain bash with no dependencies of its own: it installs each distro's security
packages, enables their systemd services in the order that distro actually needs, and
exposes two commands — `av-scan` and `av-setup` — that behave the same on all three.

It ships no scanner. Everything it runs is a distro package:

| It installs | It then runs |
|---|---|
| ClamAV — `clamav`, plus `clamav-daemon` and `clamav-freshclam` on Debian/Ubuntu | `clamdscan` / `clamscan`, `freshclam` |
| `rkhunter` | `rkhunter --check --sk --nocolors` |
| `chkrootkit` — Debian repo; **AUR-only on Arch**, where `av-setup` cannot install it | `chkrootkit` |
| AIDE — `aide`, plus `aide-common` on Debian/Ubuntu | `aide --check`, or `aide.wrapper --check` on Debian |
| auditd — `audit` on Arch, `auditd` on Debian | nothing. It enables the daemon and deliberately writes **no** audit policy; add your own rules under `/etc/audit/rules.d/`, or the daemon records nothing useful |

Everything user-facing is an env var with a default, and every entrypoint resolves its
own repo root through symlinks, so one checkout serves any user on any of the three
distros without editing a line.

---

## Fleet position

linux-av is **Linux-only**, and it is reached through exactly one path.

**os-config never runs it.** os-config detects the OS, reads `targets.tsv`, and runs one
entrypoint per matching row. The linux base row's entrypoint is `linux-config`'s
`install.sh`. linux-av's name appears in that row's sixth field, `deps` — which os-config
uses for sibling-inspection warnings only. That field does not dispatch anything.

The real invocation is **`linux-config`'s `linux-av` role**, which runs this repo's
`bootstrap.sh` as a **child process** and never sources its shell library. linux-config
forwards only flags linux-av documents, behind its own `--av-*` spellings, and never
implies any of them from `--all` — because `--av-full` rewrites the default scan target
for every user on the box.

```
os-config ──runs──▶ linux-config install.sh ──runs──▶ linux-av bootstrap.sh
          (linux base row)          (linux-av role, child process only)
```

Two properties of this repo that the chain depends on:

- **No Windows counterpart, by design.** The windows base row names no AV repo at all.
  linux-av must not grow one; the Windows half of the fleet has no equivalent.
- **An unknown flag is fatal, never ignored.** Every entrypoint here exits non-zero on an
  unrecognised option (`die` exits 1). A caller that guesses a flag name kills the install
  rather than silently doing less than it claimed. This is why linux-config forwards only
  documented flags.

---

## Where you install from is permanent

`av-scan --install-timer` and `--install-rootkit-timer` write **root-owned unit files into
`/etc/systemd/system/`** whose `ExecStart` is an absolute path back into this checkout.

`install_timer()` in `bin/av-scan` (line 178) chooses that path:

```bash
local bin; bin="$(command -v av-scan || echo "$AV_HOME/bin/av-scan")"
```

and substitutes it for `@BIN@` in `systemd/av-scan.service` or `systemd/av-rootkit.service`.
Both branches lead back into this directory:

- **`command -v av-scan` succeeds** — that is the symlink `install.sh` planted
  (`ln -sfn "$REPO/bin/$tool"`), so root runs a link whose target is inside the checkout.
  Nothing is ever copied out of it.
- **It fails** — `$AV_HOME` is written into the unit literally. `AV_HOME` is computed at the
  top of every entrypoint by walking `BASH_SOURCE[0]` through its symlinks and taking the
  parent directory, so it always resolves to this checkout's root.

**Consequence: move, rename or delete the checkout and root's timers break at their next
firing, with nothing in the repo to warn you.** Clone somewhere permanent and system-wide
before installing a timer — not into a home directory you may reorganise, not into a cache
or temp directory, not into a per-user path if the box has more than one user.

This is also why the fleet proves the link before trusting it: linux-config will only
execute `av-setup status` after confirming that both `av-scan` and `av-setup` on `PATH`
resolve, as symlinks, into its own linux-av clone. A binary of the same name that resolves
somewhere else is a different tree, and root would be the one running it.

---

## Commands

### First run on a box — `bootstrap.sh`

Run as your **normal user**. It escalates with `sudo` itself, and the `--aide` source build
refuses to run as root. It is idempotent.

```bash
# inside a checkout you already have
./bootstrap.sh --system --full --onaccess --aide \
    --timer 86400000 --rootkit-timer 604800000

# on a fresh box, cloning first
REPO_URL=<remote>/linux-av.git ./bootstrap.sh --system --full --onaccess --aide \
    --timer 86400000 --rootkit-timer 604800000
```

| Flag | Effect |
|---|---|
| `--repo <url>` (or `REPO_URL=`) | remote to clone from when not already inside a checkout |
| `--dir <path>` | where to clone or expect the checkout (default `~/linux-av`) |
| `--system` | symlink the commands into `/usr/local/bin` instead of `~/.local/bin` |
| `--full` | writes `AV_SCAN_PATHS="/"` into `/etc/linux-av/av.env` — changes the default scan target **for every user on the box** |
| `--onaccess` | enable ClamAV real-time protection |
| `--aide` | install AIDE (on Arch, the libgcrypt source build via `av-aide-arch`) |
| `--timer <ms>` | install the persistent scan timer |
| `--rootkit-timer <ms>` | install the persistent rkhunter + chkrootkit timer |

**Intervals are MILLISECONDS**, everywhere in this repo. `86400000` is one day,
`604800000` is seven. `--scheduled` uses the same unit.

### PATH only — `install.sh`

```bash
./install.sh            # per-user  -> ~/.local/bin   (no root)
sudo ./install.sh -s    # system    -> /usr/local/bin (all users)
```

Symlinks `av-scan`, `av-setup` and `av-aide-arch` out of `bin/`. Installs no package and
enables no service. Because they are symlinks, `git pull` updates every box in place.

### Packages and services — `av-setup`

```bash
av-setup all        # install + enable — the usual first run
av-setup install
av-setup enable
av-setup onaccess
av-setup status
```

Needs root and re-execs itself through `sudo -E` if you forget. An unknown subcommand is fatal.

The cross-distro trap this command exists to hide: **Arch auto-enables nothing, and
`freshclam` must seed the signature database once before `clamav-daemon` will start at all.**
Debian and Ubuntu enable `clamav-freshclam`, `clamav-daemon` and `auditd` at package-install
time, so `enable` there verifies rather than starts. On Arch, `aide` and `chkrootkit` are
AUR-only and `av-setup` cannot install them — makepkg refuses to run as root — so it warns
and points you at `av-aide-arch` and your AUR helper.


`enable` also decides where the scanners' reports go. With no `mail` or `sendmail` on `PATH` it sets
`MAILTO=""` in `/etc/chkrootkit/chkrootkit.conf`, `MAILCMD=":"` in `/etc/default/aide` (an empty
`MAILTO` would not work there: `dailyaidecheck` defaults it to `root`) and `REPORT_EMAIL=""` in
`/etc/default/rkhunter`; each edit is one variable line, backed up once as `<file>.linux-av.bak`,
idempotent, and skipped when a mailer exists or `AV_QUIET_REPORTS=0`. A symlinked file, a file whose backup cannot be made, and an edit that would leave the file unparsable are left alone with a warning. On Debian/Ubuntu it turns on
rkhunter's nightly run (`CRON_DAILY_RUN` and `CRON_DB_UPDATE` set to `"true"`, then
`rkhunter --propupd` once when `rkhunter.dat` is missing; `AV_RKHUNTER_DAILY=0` skips it). The AIDE
baseline builds in a systemd unit of its own (`linux-av-aide-init`, started with `systemd-run
--collect`), so it outlives the terminal; a unit already running is not started again.
`av-setup chkrootkit-baseline` (also run by `enable`) copies chkrootkit's `log.today` to
`log.expected` when it is not empty, has no `INFECTED`, `Vulnerable`, `WARNING` or `Warning` line (otherwise it lists them and prints the `cp -a` command for after reading), and `log.expected`
is absent. `av-setup status` prints each scanner's report location and mail state, the AIDE baseline
(present, building, absent), the chkrootkit baseline and whether rkhunter's daily run is on.

**Where each report lands** (what device-health's planned `av-status` check reads, R-2762):

| Scanner | Report | Baseline |
|---|---|---|
| AIDE | `/var/log/aide/aide.log` (and `journalctl -u dailyaidecheck`) | `/var/lib/aide/aide.db` (`.gz` on Arch); building: `systemctl status linux-av-aide-init` |
| chkrootkit | `journalctl -u chkrootkit` and `/var/log/chkrootkit/log.today` | `/var/log/chkrootkit/log.expected` |
| rkhunter | `/var/log/rkhunter.log` (the cron job runs `rkhunter --cronjob --report-warnings-only --appendlog`; nothing is mailed) | `/var/lib/rkhunter/db/rkhunter.dat` |
| ClamAV scans | `/var/log/linux-av/` (the timers' logs) | none |

### Tests — `tests/run.sh`, `tests/mutants.sh`

```bash
tests/run.sh                  # every row, 39 at the time of writing; or name rows to run
tests/mutants.sh              # one guard removed per scratch copy; each named row must go red
```

Bash, no root, no dependencies. `AV_ROOT` (empty by default) prefixes every `/etc` and `/var`
path the new code reads or edits; each row builds a scratch root and a `PATH` of symlinks to plain
tools plus stubs for `systemctl`, `systemd-run`, `rkhunter`, `aideinit`, `aide` and `id`
(and `mail` / `sendmail` where a row wants a mailer). `tests/mutants.sh` copies the checkout, applies
one sed per guard, checks the copy still parses, and reports `killed` or `SURVIVED`; it exits 1 on a
survivor. Set `TMPDIR` to a scratch directory; `AV_TEST_KEEP=1` keeps the rows' scratch trees.

### Scanning — `av-scan`

```bash
av-scan --now                  # one scan of $AV_SCAN_PATHS (default: $HOME)
av-scan --quick                # $HOME /tmp /var/tmp
av-scan --full                 # whole filesystem
av-scan --path /srv --now
av-scan -q --now               # quarantine anything infected
av-scan --update               # refresh signatures (freshclam)
av-scan --rootkit              # rkhunter + chkrootkit
av-scan --integrity            # AIDE file-integrity check
av-scan --status
av-scan --scheduled 10000      # foreground loop every 10000 ms — for testing, not production
```

Root-only, and these are the ones that write units:

```bash
sudo av-scan --install-timer 86400000
sudo av-scan --remove-timer
sudo av-scan --install-rootkit-timer 604800000
sudo av-scan --remove-rootkit-timer
```

**Scanning the whole box takes two things, not one:** target `/` (`--full`, or
`AV_SCAN_PATHS=/`) **and** run as root. Without root, files you cannot read — other users'
homes, system paths — are skipped silently and the scan still reports success. The installed
timer already runs as root.

Engine selection is automatic: `clamdscan` when a daemon socket is found, `clamscan`
otherwise, and always `clamscan` for a whole-root scan, because `clamdscan` cannot apply
`AV_EXCLUDE_DIRS`. Force it with `--engine clamscan|clamdscan` or `AV_ENGINE`.

### AIDE on Arch — `av-aide-arch`

```bash
av-aide-arch            # fetch AUR PKGBUILD, force --without-nettle --with-gcrypt, makepkg -sif
av-aide-arch --rebuild  # clean rebuild
```

AIDE's release does not compile against `nettle >= 3.10`; this builds it against libgcrypt,
whose code path is unaffected. Run as your normal user — makepkg refuses uid 0. AIDE is
optional: the ClamAV / rkhunter / chkrootkit / auditd stack is fully functional without it.

---

## File map

Every tracked file in this repository.

| Path | What it is |
|---|---|
| `MASTER.md` | This file. The stable entry point: what the repo is, its fleet position, the commands and their real flags, and where state lives. |
| `README.md` | **The full manual, and the only other Markdown file here.** Holds the per-distro reference tables (package names, which services auto-enable, AIDE database paths and check binaries, AppArmor defaults), the long-form on-access and whole-box scanning notes, the makepkg-versus-packaged-install comparison behind `av-aide-arch`, and the uninstall steps. Go there when you need the *reasoning* behind a distro branch or the exact per-distro prerequisite commands — this file carries the interface, the README carries the detail. |
| `bootstrap.sh` | One-shot per-box rollout: locate or clone the checkout, run `install.sh`, run `av-setup all`, then optionally AIDE, whole-box config, on-access and both timers. Run as a normal user; escalates itself. |
| `install.sh` | Symlinks the three `bin/` commands onto `PATH`. Copies nothing. |
| `bin/av-scan` | The scan runner: immediate, quick, full, path-scoped, scheduled-foreground, rootkit, integrity, status — and the code that renders and installs the root-owned systemd timers. |
| `bin/av-setup` | Installs packages and enables services per distro; also configures on-access scanning, the AIDE check timer's boot-delay drop-in, the scanners' report destinations and rkhunter's nightly run, and starts the AIDE baseline in its own unit. Needs root (`status` does not). |
| `lib/reports.sh` | Sourced by `av-setup`. The report-destination edits, the detached AIDE baseline, the chkrootkit baseline and the `status` report lines; every `/etc` and `/var` path goes through `av_path` (prefix `AV_ROOT`). |
| `tests/run.sh` | The suite: 39 rows, bash only, no root. |
| `tests/mutants.sh` | Removes each guard of the new code in a scratch copy and checks the named row goes red. |
| `bin/av-aide-arch` | Arch-only AIDE build: fetches the AUR PKGBUILD, forces the gcrypt backend, `makepkg -sif`. Must not run as root. |
| `lib/common.sh` | Sourced by all three commands. Resolves `AV_HOME` through symlinks, loads `av.env`, defines every `AV_*` default, detects the distro, maps package names, and provides logging plus `die` / `have` / `need_root`. |
| `systemd/av-scan.service` | Template for the scheduled ClamAV scan. `@BIN@` and `@PATHS@` are filled in at install time; runs as root with `AV_LOG_DIR=/var/log/linux-av`. |
| `systemd/av-rootkit.service` | Template for the scheduled rkhunter + chkrootkit run. `@BIN@` filled in at install time. |
| `systemd/av-scan.timer` | Generic timer template driving either service. `@BOOTDELAY@`, `@INTERVAL@`, `@NAME@` filled in at install time; `Persistent=true` catches up a run missed while the box was off. |
| `config/av.env.example` | Every tunable with its built-in default, commented out. Copy it to one of the config locations below. |
| `.gitignore` | Excludes the local runtime artifacts — `config/av.env`, logs, `quarantine/`, `state/`. |
| `LICENSE` | MIT. |

---

## Where state lives

None of this is in git, and none of it is removed by deleting the checkout.

| Path | What | Written by |
|---|---|---|
| `/etc/linux-av/av.env` | system-wide config. `bootstrap.sh --full` writes `AV_SCAN_PATHS="/"` here, editing in place rather than replacing the file | `bootstrap.sh` |
| `~/.config/linux-av/av.env` | per-user config | you |
| `<repo>/config/av.env` | repo-local config; gitignored | you |
| `~/.local/state/linux-av/` | per-user logs, scan state and quarantine — `AV_LOG_DIR`, with `AV_QUARANTINE` and `AV_LOG_FILE` beneath it | `av-scan` |
| `/var/log/linux-av/` | the timers' logs. The unit templates set `AV_LOG_DIR` here, so timer output does **not** land in the user tree | timer units |
| `/etc/systemd/system/linux-av-scan.service` and `.timer` | the rendered scan timer, `ExecStart` pointing into this checkout | `av-scan --install-timer` |
| `/etc/systemd/system/linux-av-rootkit.service` and `.timer` | the rendered rootkit timer | `av-scan --install-rootkit-timer` |
| `/etc/systemd/system/aidecheck.timer.d/10-linux-av-bootdelay.conf` (or under `dailyaidecheck.timer.d/`) | drop-in adding `OnBootSec` + `Persistent=true`, so the packaged AIDE check also runs after boot instead of only at a fixed clock time | `av-setup enable` |
| `/etc/clamav/clamd.conf` | `OnAccess*` directives appended and reconciled | `av-setup onaccess` |
| `/etc/logrotate.d/linux-av-clamonacc` | rotation for the packaged on-access log, added only when no existing policy covers it | `av-setup install` |
| `/var/lib/aide/aide.db` (`.gz` on Arch) | the AIDE baseline database, built by the `linux-av-aide-init` unit | `av-setup enable` |
| `<file>.linux-av.bak` beside `/etc/chkrootkit/chkrootkit.conf`, `/etc/default/aide`, `/etc/default/rkhunter` | the file as it was before the first report-destination edit | `av-setup enable` |
| `/var/log/chkrootkit/log.expected` | chkrootkit's expected output, adopted from `log.today` | `av-setup chkrootkit-baseline` |
| `~/.cache/linux-av/` | `av-aide-arch` build tree — `AV_AIDE_BUILD_DIR` | `av-aide-arch` |

Config lookup, first found wins:
`$AV_CONFIG` → `~/.config/linux-av/av.env` → `/etc/linux-av/av.env` → `<repo>/config/av.env`.
Every tunable is a plain env var, so exporting it works just as well as a file.

The installed unit basenames are `linux-av-scan` and `linux-av-rootkit` by default
(`AV_TIMER_NAME`, `AV_ROOTKIT_TIMER_NAME`). Change them before installing a timer, or
`--remove-timer` will not find what you installed.

---

## Pointers

- **`README.md`** — the full manual. Go there for the per-distro difference tables, the
  detailed on-access and whole-box scanning discussion, and the uninstall procedure.
- **`config/av.env.example`** — the authoritative list of `AV_*` variables and their
  defaults. Read it before setting any of them rather than guessing a name.
- **`lib/common.sh`** — the single source of distro detection, config resolution, package-name
  mapping and every default. Go there first when a distro branch behaves unexpectedly; all
  three commands read their world from this file.
- **`roles/linux-av.sh` in the sibling `linux-config` repo** — the contract the fleet holds
  this repo to: child-process invocation only, no dot-sourcing of `lib/common.sh`, no `--av-*`
  flag the operator did not ask for, and a read-only probe. Go there before changing any
  entrypoint's flags, subcommands or exit codes, because that role is what breaks.
- **`docs/FLEET.md` in the sibling `os-config` repo** — the fleet-wide map and the callee
  contract every repo in it must satisfy. Go there when you need to know how the callers
  chain, or what a caller is entitled to assume about this repo's exit codes.
