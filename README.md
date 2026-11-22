# linux-av

A small, portable antivirus + host-protection toolkit for **Arch, Debian and
Ubuntu** boxes. It wraps ClamAV (plus rkhunter, chkrootkit, AIDE and auditd)
behind two commands you can drop on every machine:

```bash
av-setup all               # install + enable the stack, the right way for this distro
av-scan  --now             # scan now
av-scan  --scheduled 10000 # scan every 10000 ms (= 10 seconds), in the foreground
```

The scripts detect the distro at runtime and branch only where the distros
actually differ (package names, a couple of paths, and — crucially — *what gets
auto-enabled on install*). Everything user-facing is driven by **env vars with
sane defaults** and **relative, symlink-following path resolution**, so the same
git checkout works for unprivileged use on all three distros. Root automation
requires the verified permanent installation described under Surface upgrade below.

See [MASTER.md](MASTER.md) for the repo's entry point: its position in the fleet, the
commands and their flags, and where state lives on a provisioned box.

---

## 0. Fastest path — `bootstrap.sh`

First complete the verified permanent installation below. Then run this **on each box**; it clones (if needed), installs the commands, installs
+ enables the AV stack, and can add a scan timer — in one go:

```bash
# from a checkout you already have (run as your normal user):
./bootstrap.sh --full --onaccess --aide --timer 86400000 --rootkit-timer 604800000

# from scratch on a fresh box (clones first):
REPO_URL=<remote>/linux-av.git ./bootstrap.sh --system --full --onaccess --aide \
    --timer 86400000 --rootkit-timer 604800000
```

Run it **as your normal user** — it escalates with `sudo` itself, and the
`--aide` source build must not be root. `--full` scans the **whole box** (§4.1),
`--system` installs for all users, `--onaccess` turns on real-time protection,
`--aide` installs AIDE, and `--timer`/`--rootkit-timer` add the scheduled scans
(each also runs ~1 min after every boot). Exact per-distro commands are below.

## 0.1 Full setup — commands per distro

`bootstrap.sh` auto-detects the distro, so the **one-liner is identical
everywhere** — only the prerequisites differ.

**Arch** (and Manjaro / EndeavourOS):
```bash
sudo pacman -S --needed git base-devel        # git + makepkg toolchain (for --aide)
paru -S chkrootkit                            # chkrootkit is AUR (or: yay -S chkrootkit)
git clone https://github.com/danganhtu01/linux-av.git ~/linux-av && cd ~/linux-av
./bootstrap.sh --system --full --onaccess --aide --timer 86400000 --rootkit-timer 604800000
```
clamav/rkhunter/audit come from the official repos; **AIDE is built from the AUR
against libgcrypt** (nettle 3.10+ breaks the default build); nothing auto-enables
on Arch, so bootstrap does it.

**Debian / Ubuntu** (and Mint / Pop!_OS / Raspberry Pi OS):
```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/danganhtu01/linux-av.git ~/linux-av && cd ~/linux-av
./bootstrap.sh --system --full --onaccess --aide --timer 86400000 --rootkit-timer 604800000
```
clamav / clamav-daemon / rkhunter / chkrootkit / aide / auditd all come from apt,
the ClamAV + auditd services auto-enable on install, and AppArmor is already on.
Bootstrap installs these with `--no-install-recommends` so AIDE's optional
mail-reporting packages do not pull in and expose a full mail transport agent.

**What each flag turns on:**

| Flag | Effect |
|---|---|
| `--system` | commands in `/usr/local/bin` for all users |
| `--full` | scan `/` (whole box); updates `AV_SCAN_PATHS` in `/etc/linux-av/av.env` without replacing other settings |
| `--onaccess` | ClamAV real-time protection (watches `/home` under `--full`) |
| `--aide` | install AIDE (Arch: libgcrypt source build; Debian: apt) |
| `--timer <ms>` | full-scan timer: ~1 min after boot, then every `<ms>` |
| `--rootkit-timer <ms>` | rkhunter+chkrootkit timer: ~1 min after boot, then every `<ms>` |

---

## 1. Layout

```
linux-av/
├── bin/
│   ├── av-scan            # scan runner: --now / --scheduled <ms> / timers / rootkit / integrity
│   ├── av-setup           # installs packages + enables services per distro
│   └── av-aide-arch       # builds/installs AIDE on Arch against libgcrypt (AUR)
├── lib/
│   └── common.sh          # distro detection, path/env resolution, logging (sourced by all)
├── systemd/
│   ├── av-scan.service    # scan-timer service template (rendered by --install-timer)
│   ├── av-rootkit.service # rootkit-timer service template
│   └── av-scan.timer      # generic timer template (boot delay + interval)
├── config/
│   └── av.env.example     # the common tunables, with defaults — copy to av.env
├── bootstrap.sh           # one-shot per-box rollout (clone → install → enable)
├── install.sh             # symlinks the commands onto your PATH
└── LICENSE                # MIT
```

## 2. Install the tools (no distro packages yet)

Clone the repo on each box, then symlink the commands onto your `PATH`. This is
what makes `av-scan` runnable as a bare command in any bash terminal — the
`install.sh` script just does `chmod +x` on the tools and `ln -s`es them into a
bin directory:

```bash
git clone <your-remote>/linux-av.git ~/linux-av    # or copy the folder over
cd ~/linux-av

./install.sh          # per-user  -> ~/.local/bin/av-scan   (no root)
# or
sudo ./install.sh -s  # system    -> /usr/local/bin/av-scan (every user)
```

If `~/.local/bin` isn't on your `PATH`, `install.sh` prints the one-liner to add
it. After this, `av-scan` and `av-setup` work from anywhere.

> **Doing it by hand instead?** That's all `install.sh` does:
> ```bash
> chmod +x ~/linux-av/bin/av-scan ~/linux-av/bin/av-setup ~/linux-av/bin/av-aide-arch
> ln -s ~/linux-av/bin/av-scan      ~/.local/bin/av-scan
> ln -s ~/linux-av/bin/av-setup     ~/.local/bin/av-setup
> ln -s ~/linux-av/bin/av-aide-arch ~/.local/bin/av-aide-arch
> ```
> Symlinking (not copying) means `git pull` updates every box in place.

## 3. Install + enable the AV stack

```bash
av-setup all        # = av-setup install  +  av-setup enable   (re-execs via sudo)
av-setup enable --keep-aide-baseline   # enable, but keep the AIDE database already there
av-setup status     # what's installed / running, where reports go, baselines
```

`av-setup` hides the biggest cross-distro trap for you:

| Behavior on install | Arch | Debian / Ubuntu |
|---|---|---|
| Services auto-started? | **No** — Arch enables nothing | **Yes** — `clamav-freshclam`, `clamav-daemon`, `auditd` start on install |
| Virus DB seeded? | **No** — you must `freshclam` once before `clamav-daemon` will start | Yes — the freshclam daemon seeds it |
| `chkrootkit` source | **AUR** (`yay -S chkrootkit`) | official repo (`apt install chkrootkit`) |
| AppArmor | off by default (kernel cmdline + reboot) | **on by default** |

So on **Arch**, `av-setup enable` runs `freshclam` first, then
`systemctl enable --now` on each service. On **Debian/Ubuntu** it just makes sure
the already-enabled services are up and fails clearly if a required daemon is
not actually active. `av-setup install` provisions the runtime directories
advertised by Ubuntu's packaged `clamav-clamonacc.service` (including its
quarantine and log locations) and adds log rotation for the packaged on-access
log when no existing policy covers it. Either way you end up in the same place.


### Where the reports go, and the baselines (`av-setup enable`)

No machine in the fleet has a mailer, and a report mailed to nobody is a finding that
reaches no one. `av-setup enable` therefore sends each scanner's report to the journal
or to the log the package already writes, and reads nothing from a mailer.

| Scanner | Report lands in | What `enable` changes (only when neither `mail` nor `sendmail` is on `PATH`) |
|---|---|---|
| AIDE (`dailyaidecheck`) | `/var/log/aide/` (`aide.log`) | `MAILCMD=":"` in `/etc/default/aide`. `MAILTO=""` would not do: `dailyaidecheck` reads `MAILTO="${MAILTO:-root}"`, so an empty value becomes `root`. `send_mail()` evals `$MAILCMD` when it is set, and `:` is a no-op. An existing `MAILCMD` of yours is kept. |
| chkrootkit (`chkrootkit.service`) | the journal (`journalctl -u chkrootkit`) and `/var/log/chkrootkit/log.today` | `MAILTO=""` in `/etc/chkrootkit/chkrootkit.conf`; `chkrootkit-daily` then prints the report instead of calling `mail`. |
| rkhunter (`/etc/cron.daily/rkhunter`) | `/var/log/rkhunter.log` | `REPORT_EMAIL=""` in `/etc/default/rkhunter`; the cron job then does not call `sendmail`. |

Each edit touches only that one variable line, keeps a `<file>.linux-av.bak` copy the
first time, logs what it changed, and does nothing on a second run. On a machine that
has a mailer the files are left alone. A symlinked file, a file whose backup cannot be made, and an edit that would leave the file unparsable are left alone with a warning. `AV_QUIET_REPORTS=0` turns all of this off.

**rkhunter runs nightly** on Debian/Ubuntu: `enable` sets `CRON_DAILY_RUN="true"` and
`CRON_DB_UPDATE="true"` in `/etc/default/rkhunter`, then runs `rkhunter --propupd` once if
`/var/lib/rkhunter/db/rkhunter.dat` does not exist. The job is `/etc/cron.daily/rkhunter`
(the package ships no systemd timer), so it needs a cron service; `enable` warns when it
finds none. `AV_RKHUNTER_DAILY=0` turns this off.

**The AIDE baseline builds in its own systemd unit** (`linux-av-aide-init`, `systemd-run
--collect`, `RuntimeMaxSec=$AV_AIDE_INIT_TIMEOUT`; systemd stops a longer build), so closing the terminal does not kill it
(raspberrypi5's `aideinit` died with its terminal at 22:57 and left no database). It runs the
same command as before: `aideinit -y -f` on Debian/Ubuntu, `aide --init` then the move on Arch.
Watch it with `systemctl status linux-av-aide-init` and `journalctl -u linux-av-aide-init -f`.
The periodic check is enabled at once but reports "no database" until the baseline finishes.
A unit already running is not started twice. `AV_AIDE_INIT=0` still skips the baseline.

**Keeping an AIDE database you already have: `av-setup enable --keep-aide-baseline`.** The
build above is slow (tens of minutes on a Raspberry Pi), and a plain `enable` starts it again
even when a database exists. With the option, `enable` first looks, before it changes anything,
for `/var/lib/aide/aide.db` (what Debian's `aideinit` writes) or `/var/lib/aide/aide.db.gz`
(Arch's flow); either counts on either distro, and an empty file does not. When one exists,
`enable` does everything it always does except start the baseline unit: it still enables the
periodic check and adds its boot drop-in, and prints one warning naming the database it kept
(`--keep-aide-baseline: keeping the existing AIDE database <path>; not rebuilding`). When
neither exists, it stops with an error that names both paths, and nothing has been changed; run
it without the option to build one. `av-setup all --keep-aide-baseline` takes the option too and
looks before it installs any package. `AV_AIDE_INIT=0` wins over the option (it skips AIDE
altogether) and one warning says so. `enable` and `all` refuse any other option.

**chkrootkit's baseline.** With `DIFF_MODE="true"` and no `/var/log/chkrootkit/log.expected`,
chkrootkit reports its whole output every night. `av-setup` does not run chkrootkit, so it
cannot know a clean run happened by itself. It reads the nightly run's `log.today` instead:
`sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-setup chkrootkit-baseline` (also run at the end of `enable`) copies it to
`log.expected` only when `log.today` is not empty, has no `INFECTED`, `Vulnerable`, `WARNING` or `Warning` line (otherwise it lists them and prints the `cp -a` command for after reading),
and `log.expected` does not exist. After the first night, that one command is all it takes.

`av-setup status` reports the baseline (present, building or absent), where each scanner's
report goes and whether its mail is off, and whether rkhunter's daily run is on.

### Tests

```bash
tests/run.sh          # 69 rows; or: tests/run.sh mail_edits_applied status_reports_quiet
tests/mutants.sh      # removes each guard in a scratch copy and shows its row go red
```

Bash only, no root, no dependencies. `AV_ROOT` is a path prefix (empty by default) for every
path the new code reads or edits under `/etc` and `/var`; the rows point it at a scratch tree and
put stubs for `systemctl`, `systemd-run`, `rkhunter`, `aideinit`, `aide` and `id` first on a
`PATH` that holds nothing else.

The rows named `guard_*` (OC-T-0037: `bin/av-guard`, `root-install-guard.sh`) make real root-owned and
uid-1000-owned fixtures with `chown`, so they run only as root, in a throwaway container; as any other user they
print `skip` and the summary counts them. Run them as root by name
(`tests/run.sh $(grep -o '^row_guard[a-z_]*' tests/run.sh | sed 's/^row_//')`). `tests/mutants.sh` runs the mutants named
`guard_*` only as root and every other mutant only as another user, so run it once as each. Neither file has a hook for
the tests: the guard runs as a copy whose `base=` line names the scratch root, and the installer as a copy whose
`base=`, `PATH=` and pin lines differ; a row proves each copy differs by those lines alone.

### Real-time (on-access) scanning — optional
```bash
av-setup onaccess   # appends OnAccess* to /etc/clamav/clamd.conf, enables clamav-clamonacc
```
Not on by default anywhere. It watches `AV_ONACCESS_PATHS` (default: your scan
paths, but **never `/`** — on-access can't watch the whole root fs, so it falls
back to `/home`) and blocks access to infected files. It also auto-adds the
`OnAccessExcludeUname` directive that clamonacc *requires* (excluding the
scanner's own user) to avoid an infinite scan loop. Every configured watch path
must already exist. On Debian/Ubuntu, setup discovers and creates the packaged
unit's quarantine/log directories, then waits briefly and verifies that
`clamav-clamonacc.service` both stays active and successfully establishes every
requested watch instead of trusting an early `systemctl start` success. Setup
also reconciles existing `OnAccessIncludePath` lines to this value, so narrowing
and rerunning takes effect. If the scheduled ClamAV service is already scanning,
a configuration-changing rerun exits clearly instead of restarting the daemon
under that scan; rerun it after the scan finishes. Narrow it with
`AV_ONACCESS_PATHS='/home /srv'`.

Large build trees can exceed the host's inotify watch capacity even while the
service process remains active. The readiness check treats those initialization
errors as setup failures; choose narrower existing paths rather than assuming
an active process means the whole tree is protected.

## 4. Using `av-scan`

```bash
av-scan --now                     # one scan of $AV_SCAN_PATHS (default: $HOME)
av-scan --quick                   # $HOME /tmp /var/tmp
av-scan --full                    # whole filesystem (/), excludes /proc /sys ...
av-scan --path /srv --now         # a specific path
av-scan -q --now                  # quarantine anything infected (moves the file)
av-scan --update                  # refresh signatures (freshclam)
av-scan --rootkit                 # rkhunter + chkrootkit
av-scan --integrity               # AIDE file-integrity check
av-scan --status                  # engine, socket, services, paths
```

`av-scan` prefers **`clamdscan`** (talks to the running daemon — fast, low RAM)
and falls back to **`clamscan`** (standalone) when no daemon socket is found.
Because `clamdscan` cannot apply `AV_EXCLUDE_DIRS`, a whole-root (`/`) scan
automatically switches to `clamscan`. A narrower scan also switches when it contains
a mount excluded by `AV_EXCLUDE_FSTYPES`. If `clamscan` is missing, it warns that
the daemon cannot enforce those exclusions.
Force either engine with `--engine clamscan|clamdscan` or `AV_ENGINE=`.

### Mains-only scans — OC-T-0139 / R-4089

All linux-av scan entrypoints require mains power. Manual work exits **75** when
deferred or cancelled. `--wait-for-mains` waits and retries an interrupted scan
from the beginning; the foreground `--scheduled` loop and installed scan/rootkit
templates use this recovery behavior. Cancelled scans never advance completion
stamps. This policy is independent of distro and scanner engine.

`lib/common.sh` reads `/sys/class/power_supply/*` by **type**, not adapter or
battery name. Mains, USB (including USB-C/PD variants), Wireless and BrickID
supplies are recognized. A present system Battery (or UPS) requires positive
external `online=1` and a known non-discharging status. Discharging wins over
a stale online adapter; unknown/missing battery status or supply type defers
work. Device-scoped peripheral batteries are ignored. An empty readable class
or absent battery slot permits mains-only servers; missing/unreadable sysfs
defers work. A UPS can report mains through its own online attribute.

The command supervisor checks power before starting and while work runs. On
loss it freezes and kills the process tree, including timeout groups, scanner
children and batch workers. Checks normally occur every second; detection and
service-manager scheduling impose a small cancellation delay, not a physical
zero-latency guarantee. Forced cancellation can leave private scan scratch
directories (`av-scan.*` in TMPDIR and `av-scan-state.*` in the log directory);
these are never accepted as completion stamps.

`av-setup install`, `enable`, `all` and `onaccess` install the same managed
`linux-av-power.service` guardian and `40-linux-av-power.conf` service drop-ins.
They gate service startup with the shared check, kill entire scanner cgroups
without waiting for graceful daemon draining, and queue interrupted/due work
under `/run/linux-av-power/pending`. Enabled continuous protection and pending
checks recover on mains. Scanner services bind to the guardian's lifetime.
`AV_AIDE_INIT=0` still skips baseline creation and periodic-check enablement;
power gates also apply to AIDE jobs an administrator already enabled. Policy
installation does not activate the guardian; perform its separate activation
before expecting delegated ClamAV/on-access protection.
`clamav-daemon.socket` is stopped on battery too; attempted socket activation
still encounters the daemon's service gate.

Inventory of repository-managed work:

| Path | Enforcement and recovery |
|---|---|
| `av-scan --now` (quick/full/path/changed/quarantine), `--scheduled` | Shared command supervisor, including file walks and all batches; scheduled work retries on mains |
| `av-scan --rootkit`, `--integrity` | Same supervisor for rkhunter, chkrootkit, aide/aide.wrapper; manual work returns 75, scheduled rootkit work retries |
| `clamdscan` and its delegated multiscan workers | Requires active `linux-av-power.service` and `clamav-daemon.service`; client is pinned to a packaged local Unix socket via a generated config, overriding TCP settings; guardian kills the daemon cgroup and queued work on battery |
| `clamav-clamonacc.service` + `clamav-daemon.service` | Both startup-gated and killed on battery; enabled services restored on mains; real-time protection is intentionally absent on battery |
| `linux-av-scan` / `linux-av-rootkit` units (configured basenames supported) | Templates wait/retry; policy upgrade adds gates and an ExecStopPost hook to replay self-cancellation (exit 75), migrating supported ExecStart paths to the permanent launcher, retaining arguments, guards and limits |
| Packaged `chkrootkit`, `rkhunter`, `aidecheck`, `dailyaidecheck` services | Startup gates, cgroup cancellation, and pending replay on mains; timer schedules stay intact, with timer-level AC conditions cleared so due events reach the service gate; timer activation remains an operator step |
| Existing `/etc/cron.daily/{rkhunter,chkrootkit,aide,aide-common}` | Wrapper runs the preserved distro script through the supervisor; waits/retries on mains, uses flock to coalesce repeats; preserves report/config behavior |
| Detached AIDE baseline and terminal fallback; `rkhunter --propupd` during enable | Baseline unit wraps the command and waits/retries; terminal fallback and property refresh defer/cancel on battery |
| `freshclam`, `clamav-freshclam`, rkhunter's weekly signature/database refresh | Signature refresh, outside scan gating; available on battery |
| apt/pacman, `av-aide-arch` / makepkg, auditd, report/baseline adoption | Package/build/administration or audit work, outside scan gating; package installation places daemon gates before maintainer scripts can start services and reapplies policy afterward |

A refresh embedded in a distro's daily scan script follows that whole script's
power policy; the wrapper preserves the packaged script's behavior.

**Surface: verified permanent installation / upgrade (OC-T-0139).** Root
entrypoints use `/usr/local/lib/linux-av/bin/av-root`; a checkout or a symlink
installed by `install.sh` is not a root deployment. `av-root` checks
`av-guard --power`, clears the inherited environment, and starts privileged Bash
without startup files. Only `/etc/linux-av/av.env` is sourced for root; HOME,
XDG, `AV_CONFIG`, repo-local config, exported functions and inherited `AV_*`
settings cannot select another file. The validated scan-scope string `AV_SCAN_PATHS` and finished-unit status 75 are
carried through; executable/config/state selectors are reset. Power sysfs, inventory and runtime paths are fixed. Root settings,
including scan scope (default `/root`; existing unit scopes are preserved), belong in the root-owned system config.
Review that config as executable shell, including anything it sources or calls.

`root-install-power.sh` reuses the pinned root-install model: an independently
verified root-private installer copies all 13 pinned inputs into private staging,
checks those copies, disables and drains legacy package dispatch as described below,
backs up changed installed files once, and installs regular
root:root files under `/usr/local/lib/linux-av` (0755 commands, 0644 libraries and
templates). Nothing from the caller-owned tree is executed or sourced. The
installed setup then renders the guardian, inventory, service/timer drop-ins and
cron wrappers, and migrates supported scan ExecStart lines, including
`root-owned.conf`, to `av-root`. Scan arguments, guards, CPU/memory/time limits
and other unit bytes are retained. Unknown scan commands, environment-file
inputs, links, foreign owners and group/other-writable paths refuse. Effective
systemd fragments, drop-ins and environment-file paths are checked too. OS
aliases are accepted there only if root owns the alias and its resolved path is
safe. Effective toolkit commands are checked after daemon-reload.

Supported scan commands use exactly `--now` for scan and `--rootkit` for rootkit.
Prefixes for migration are `/usr/local/bin/av-scan`,
`/usr/local/lib/linux-av/bin/av-scan`, and the new `/bin/sh
/usr/local/lib/linux-av/bin/av-root av-scan`. Custom unit basenames must already
be set in `/etc/linux-av/av.env` and listed in an existing inventory when
quiescing. The exact historical Surface base command
`/home/atdang/.cache/os-config/repos/danganhtu01/linux-av/bin/av-scan`
is accepted only as unit-file data for the default scan/rootkit units: one base
ExecStart, matching intended argument, and a loaded `root-owned.conf` with an
empty ExecStart reset followed by the matching permanent av-scan command.
The effective command must select that permanent command with the exact
`av-guard` pre-command, root identity and fresh loaded state. All unit fragments,
drop-ins and ancestors must pass the ownership/mode audit. The writable checkout
target is never inspected, resolved, sourced or executed. Only the accepted
ExecStart lines change; original backups and other settings remain intact.
A prior `power.incomplete` gate may remain during retry and is removed only after
successful effective-policy verification. Other layouts require review; do not
bypass a refusal.

Before an operator performs this upgrade, arrange a separately authorized
maintenance window: guardian, scanner services and their timers must be inactive,
including custom units. Already-running legacy daily jobs are drained by the installer.
The cron/crond scheduler may remain active on both fresh and existing hosts;
its active state is no longer a refusal. All guardian/scanner/socket/timer and
existing custom-inventory quiescence checks remain in force. The installer
stops nothing. Record enabled and active states to restore explicitly afterward.
Do not run concurrent package transactions or administrative policy/code edits.

Before its first installed code write, the pinned installer takes an exclusive,
nonblocking `/run/linux-av-policy.lock`. A current guarded job holds the shared
lock for its whole lifetime, so installation refuses while it runs. New guarded
invocations wait on the shared lock before loading libraries/config. The lock
stays exclusive across disabling legacy dispatch, draining, code installation,
policy installation/readback and guarded-route publication. Policy-only refresh
uses the same protocol from the verified permanent copy.

For each present `/etc/cron.daily/{rkhunter,chkrootkit,aide,aide-common}` raw
package entry, the pinned `av-guard --cron-disable` first rejects links, foreign
owners, writable paths and nonregular types. It durably copies the exact regular
file bytes, uid/gid and mode into
`/etc/linux-av/cron-migration/<name>/saved.<sha256>.<uid>.<gid>.<mode>`.
Any legitimate existing `.linux-av-power-original` is archived separately,
including its original mode. A durable `pending` copy records the package being
migrated. The first `.before-OC-T-0139` backup is retained. Files are synced before
same-directory atomic rename, and their parent filesystem is synced afterward;
a sync error fails installation. The old dispatch inode is also retained as an
`open.<device>.<inode>` hard link, allowing the census to recognize a shell with
an already-open, renamed script even when its argv has no script pathname.
Canonical wrappers are disabled too: their text alone does not prove that the
previous launcher implements the shared lock. Their package originals remain
distinct; wrapper inode records are retired after successful drain/publication.
Then dispatch is atomically replaced with a root-owned 0755 inert shell script
that exits 0. Only behind that disabled route is the 0644 working package
original published. No unguarded route is introduced by installation.

All raw routes are disabled **before waiting**. The pinned `--cron-wait` runs a
read-only process census, with at most 60 attempts / 59 one-second sleeps and a
60-second worker deadline (two-second forced worker cleanup allowance). It
never signals legacy jobs or stops cron. Exact affected daily-script/original
argv paths, retained open inodes, known scanner names, `run-parts`, `anacron`,
and shell command strings containing affected paths block progress. Dispatcher
and scanner-name detection is deliberately conservative. Two clean censuses
separated by a poll are required. An inspection error fails immediately; a busy
process drains naturally or causes a plain timeout. On timeout no new code is
installed, raw dispatch stays disabled, and durable originals plus
`/etc/linux-av/power.incomplete` remain. Retry the installer after the jobs
finish; never delete the marker to bypass the gate.

Retries recognize exact inert placeholders and pending raw/wrapped states.
They validate the pending bytes/type/mode against the durable archive and never
save the placeholder as a package original. An orphan or malformed placeholder
refuses. A crash during preparation/publication can leave the original raw route
or a complete inert route, with a durable pending copy for retry; successful
parent-filesystem sync makes disabling persistent before drain/code installation.
A crash during final
publication can leave some guarded routes and some placeholders, all protected
by the persistent incomplete gate. After drain, code and policy are installed;
only successful effective-policy readback permits atomic guarded-route
publication. The incomplete gate is cleared durably last. Guarded invocations
refuse with exit 75 while it remains. Policy-only refresh checks retained release
pins, so it cannot bless a partially copied code release. Recovery is a retry,
not transactional rollback.

**Dispatcher limits:** rename cannot recall an already-open script, freeze a
process that has read its old code into memory, or lock an uncooperative legacy
scheduler. The drain inspects visible argv and retained open inodes, and waits
out visible dispatchers; even two clean censuses are not a kernel fork/exec
barrier. A hidden/renamed dispatcher, delayed fork/exec from an unrecognized
parent, copied/interpreted code with no recognizable argv or fd, alternate path
aliases, or a process appearing after its census slot can escape observation.
Complete readable host `/proc` (including fd/exe access), the same filesystem for
the daily entries and migration state (required for retained inode hard links),
ordinary distro `run-parts` naming rules excluding dotted/hidden backup files, and no concurrent
package/admin changes are required. Restricted/container process views, custom
`run-parts --regex` rules, direct invocations of preserved originals and custom
cron.d/crontab routes are unsupported. Such dispatchers need a separately
controlled maintenance window. The installer closes new opens through the four
supported entries before waiting; it does not claim OS-wide exclusion of
arbitrary legacy launchers or in-memory code.

After the imported release has passed the release checks below, obtain the
**installer SHA-256 from the trusted release/run-card channel**, independently of
the writable checkout. Export it as `LINUX_AV_INSTALLER_SHA256`. From the imported
release directory, use exactly:

```bash
: "${LINUX_AV_INSTALLER_SHA256:?set the independently verified release installer SHA-256}"
sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  /bin/bash --noprofile --norc -p -s -- "$PWD" "$LINUX_AV_INSTALLER_SHA256" <<'ROOT'
set -euo pipefail
[[ $2 =~ ^[0-9a-f]{64}$ ]]
stage=$(mktemp -d /root/linux-av-power-install.XXXXXXXX)
trap 'rm -rf --one-file-system -- "$stage"' EXIT
install -m 0600 -- "$1/root-install-power.sh" "$stage/installer"
printf '%s  %s\n' "$2" "$stage/installer" | sha256sum -c -
cd -- "$1"
/bin/sh "$stage/installer"
ROOT
```

This updates code and policy only: no packages, signature refresh, baseline,
scan, unit enable/start/stop/restart or timer-state changes. It runs
`daemon-reload` and read-backs. Backups use `.before-OC-T-0139`; cron package
originals retain `.linux-av-power-original`. A repeat is stable. A code-stage or
later read-back failure can leave part of the new release installed; keep the
maintenance window in place, retain the first backups and correct the refusal
before any activation. This is not a transactional rollback mechanism.

The installer also saves `/etc/linux-av/power.release.sha256` from the same
13-input pinned snapshot; the policy renderer saves `power.cron.sha256` beside
it for the retained original package bytes. Both are root:root 0644, backed up
once when changed and atomically replaced. This does not change the independent
installer-hash trust channel or bless a caller checkout. A policy-only refresh
does not regenerate release pins.

After successful installation, future policy-only refreshes (for example after a
package replaces a daily cron script) use:

```bash
sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-setup power-policy
```

Before linux-config changes anything on a rerun, use this exact fixed invocation
(from root automation, omit only the `sudo` prefix):

```bash
sudo /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  /bin/sh /usr/local/lib/linux-av/bin/av-root av-setup power-policy-verify
```

Success is **exit 0 and exactly these two stdout lines**, each newline-terminated:

```text
av-guard: ok
linux-av: installed power policy verified
```

Every refusal is nonzero and has no success marker. Missing/older installations
or manifests, an unknown argument, unsafe paths, unknown systemd output and
inspection errors all fail closed. linux-config must gate its rerun decision on
both the status and exact output; file presence, a guard-only success, or a skip
is not verification. On success it can skip code/policy installation when the
separately trusted release/version is already the desired one. Verification
does not choose or authenticate a new release. On refusal, report the reason and
use the independently pinned installation procedure only within its existing
maintenance preconditions; do not silently reload/repair/start anything.

The verifier reuses `av-guard --power`, policy rendering and the installer's
effective-command readback. It checks all 13 installed code/template hashes and
exact modes/uid/gid against the retained release manifest; exact rendered
guardian/inventory/service/timer/cron bytes and modes/uid/gid; supported legacy
scan-unit migration and executable restrictions; cron routing, original presence,
non-executable 0644 originals and their retained hashes; and the inventory
computed from the current root config, including custom unit basenames. For
loaded units it audits fragment/drop-in/environment-file paths, `LoadState`,
recognized `ActiveState`, `NeedDaemonReload=no`, guardian commands/runtime
settings, service gate/finish commands, guardian dependencies, cgroup kill
settings, absence of the AC conditions that bypass the queue, and effective
linux-av scan commands/extra executable inputs. Optional package units may be
`not-found`; the guardian and any locally installed configured base unit must be
loaded. Active units are permitted by this read-only command; success does not
assert that the guardian is activated or that a scan has run.

There is no staging or installed write, log append (including on failure), lock
creation, daemon-reload, service change, scan, package call or sudo escalation
inside the verifier. The explicit `sudo` above may of course audit externally.
It trusts root-authored config as executable shell, the installed entrypoint and
root-held manifests; it does not sandbox config, attest arbitrary package
configuration/transitive commands, or prove a running process's in-memory code.
The result is a point-in-time inspection, not a transaction against concurrent
root/package/systemd edits. Normal filesystem reads may update access times.

Activation is a separate, explicitly authorized operator step. On Surface, once
root configuration and the effective units have been reviewed, the guardian is
started with `sudo systemctl enable --now linux-av-power.service`; restore only
the timers/services recorded for this host. Do not use a scan restart as an
installation check. Setup and timers also use the permanent launcher, for example
`sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-setup all --keep-aide-baseline` (only when an AIDE database already exists).
`install.sh` still installs user PATH links and has no `--upgrade` flag.

OVH's existing `root-install.sh` and `root-install-guard.sh` remain separate
run-card procedures, with their hostname, CPU-cap, backup, rendering and read-back
safeguards. They do not constitute a complete power-policy deployment. This
release needs the verified permanent installation before root scans can resume;
`root-install-power.sh` also checks OVH's existing CPU cap and never starts its
scan or timer. OVH activation remains a separate card.

Release checks still required before rollout: run `bash tests/root-power.sh` as
real root in a disposable GNU/Linux container (a skip is not a pass), run the
existing root `guard_*` checks, and verify actual Surface/OVH systemd read-back
formats and host unit layouts. The new test creates a private chroot with copied
OS tools and inert service/cron fixtures; no host services or scanners are used.
The nonroot suite is `bash tests/run.sh`; `bash tests/policy.sh` separately runs
inert active-cron, actual shared/exclusive-lock and verified/mismatched-policy
checks with synthetic systemctl/proc data and simulated root metadata.
`bash tests/cron-migration.sh` runs the actual installer and policy renderer in
relocated, unprivileged copies with inert real processes, simulated root metadata,
synthetic active-cron readback and shortened polling. It proves all four raw
routes become inert before draining, timeout/retry preservation, installation
after drain, failed readback before route publication, already-open inode
detection and natural completion, interrupted migration, and invalid-type/orphan
refusals. It does not exercise the host cron daemon or attest real root ownership.
[Candidate proof and exact checks](OC-T-0139-PROOF.md) record this build's evidence and limits. The root
fixture now includes active cron, legacy drain timeouts/scanner refusals and read-only
success/mismatch snapshots; its proc/descriptor identity is synthetic, not a
mounted host proc. Root-fixture and real host readback checks require a later
approved run; neither chroot nor host actions were run for this change. Audit distro scanner
configuration and any transitive includes/commands in root-authored config;
toolkit ownership checks do not attest arbitrary package configuration or code.
An already-running old guardian must still be quiesced by the operator. Legacy
cron scripts keep their old in-memory code until they finish; drain and dispatcher
limits above apply. No host installation or activation has been
performed by this repair.

Unhandled paths: arbitrary direct scanner binary invocations, custom units or
user crontabs/cron.d entries outside the listed inventory, third-party containers,
remote/custom clamd sockets, and scanners launched independently by alert hooks.
Remote/custom socket delegation is refused by av-scan; use clamscan or the
packaged local daemon. A daemon double-forking outside a managed service is not
covered by the foreground process-tree supervisor. Rerun `power-policy` after
external package upgrades that replace the managed cron wrappers (the installer
preserves the new package script). Pending service state is volatile across
reboot; existing enabled timers/cron schedules provide the next run. The
permanent root-owned installation remains available independently of the checkout.
The policy is not an OS-wide prohibition on privileged users launching scanners.

`bash tests/power.sh` exercises synthetic power supplies and harmless process
stand-ins, including a delegated daemon in a separate session; it is also run
by `tests/run.sh`. No real scan, install or host service operation is needed.

Each scan checks a lexical absolute path against skipped mounts before any
`realpath` call, so a path already on a dead network mount is dropped without
probing it. Remaining paths resolve with `realpath -m`, including symlinks with
missing components; only a failed resolution keeps the lexical absolute form.
The resolved paths are checked again and passed to the scanner.
It reads `/proc/self/mountinfo` (`AV_MOUNTINFO` overrides it), using mount IDs and
parent IDs so only mounts that path lookup can reach count: covered entries and
their hidden children are ignored, while the top of a stack remains visible.
Remote filesystems, automounts, `fuse`, and `fuse.*` are skipped by default.
A scan path on a skipped mount is dropped with a warning; if none remain, the
scan returns 0 without starting a scanner. Mount points below a selected path
add escaped, anchored `--exclude-dir` and `--exclude` regexes, covering directories
and file mounts, so excluding `/srv/cloud` keeps `/srv/cloud2`.
`AV_EXCLUDE_FSTYPES` accepts space-separated shell patterns. Local `fuseblk` disks
and other local filesystems remain included unless reached through a skipped mount.

`AV_SCAN_TIMEOUT=12h` bounds each scanner invocation with `timeout --kill-after=5m`.
`AV_SCAN_TIMEOUT=0` removes the limit. A timeout logs that the scan did not finish
and returns 124, distinct from threats (1). Status 137 reports SIGKILL: either
the time limit's kill-after or another killer, such as the OOM killer.

### 4.1 Scanning the whole box (all users + mounted drives)

**By default `av-scan` scans only `$AV_SCAN_PATHS` (i.e. `$HOME`) as your own
user** — it does *not* touch other users' homes, system dirs, or mounts. To
cover the whole machine you need **both**:

1. **Target `/`** — pass `--full` (or set `AV_SCAN_PATHS=/`, which
   `bootstrap.sh --full` writes to `/etc/linux-av/av.env`).
2. **Run as root** — otherwise files you can't read (other users' dirs, system
   files) are silently skipped. The systemd timer already runs as root; by hand,
   use `sudo`.

```bash
sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --full --now            # entire filesystem, as root
sudo env AV_SCAN_PATHS=/ /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --now   # same, via env
```

What a root `--full` scan **does** and **does not** cover:

- ✅ **Other users' home directories** — yes, when run as root.
- ✅ **Mounted drives** (USB, extra disks, bind mounts) — yes; ClamAV crosses
  filesystem boundaries by default, so mounted local filesystems are included.
- ❌ **Network mounts, automounts, and FUSE mounts** are skipped by default through
  `AV_EXCLUDE_FSTYPES`; local `fuseblk` disks remain included.
- ❌ **Unmounted / disconnected drives** — a scan only sees what's mounted when
  it runs. Mount it first, or scan explicitly: `sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --path /mnt/disk --now`.
- ❌ **Real-time coverage** — a periodic full scan is a snapshot in time. For
  on-write/on-open protection, enable `av-setup onaccess`.

> **"Install once and it scans everything?"** You install the tools **once per
> box**, but there's no central controller — run `bootstrap.sh` on *each* box
> (or push it with your config-management tool). And "everything" only happens
> with `--full` **as root**; the default is your `$HOME` only.

### Scheduling — two ways

**A. Foreground loop** (matches your example; great for testing, no root):
```bash
av-scan --scheduled 10000     # scan, wait 10 s, repeat … Ctrl-C to stop
```
The interval is **milliseconds** (`10000` = 10 s). Sub-second values work too.

**B. Persistent systemd timer** (survives reboots; runs as root so it can read
system paths). Same units on all three distros since they all use systemd:
```bash
sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --install-timer 86400000   # every 86 400 000 ms = 1 day
sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --remove-timer
systemctl list-timers linux-av-scan.timer
```

The installed timer also fires **`AV_TIMER_BOOT_DELAY` (default 1 min) after
every boot** (`OnBootSec`), so a machine that's powered off unpredictably still
gets scanned on each startup — then repeats at your interval (e.g. daily) while
it stays on. `Persistent=true` additionally re-runs a scan that came due while
the box was off. Change the boot delay with `AV_TIMER_BOOT_DELAY=30s` before
`--install-timer`.

**Rootkit scans** (rkhunter + chkrootkit) are *not* scheduled by anything on Arch
(Debian wires a cron.daily; Arch doesn't). Give them their own timer — weekly is
plenty:
```bash
sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --install-rootkit-timer 604800000   # every 604 800 000 ms = 7 days
sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --remove-rootkit-timer
systemctl list-timers linux-av-rootkit.timer
```
This runs `av-scan --rootkit` (rkhunter `--check --sk` + chkrootkit) as root on
the interval, logging to `/var/log/linux-av/`.
> For genuine real-time protection use **on-access** (§3), not a tight
> `--scheduled` loop — a 10 s loop is meant for testing, not production.

## 5. Configuration (env vars)

Copy the example and edit — or just `export` the vars:
```bash
mkdir -p ~/.config/linux-av
cp ~/linux-av/config/av.env.example ~/.config/linux-av/av.env
```
For unprivileged commands, `av.env` is looked up in this order (first found wins): `$AV_CONFIG` →
`~/.config/linux-av/av.env` → `/etc/linux-av/av.env` → `<repo>/config/av.env`.

Key vars (all optional, shown with defaults):

| Var | Default | Meaning |
|---|---|---|
| `AV_SCAN_PATHS` | `$HOME` | what `--now` scans |
| `AV_EXCLUDE_PATTERNS` | `node_modules target .cache __pycache__ .venv .tox .gradle .claude/worktrees` | space-separated literal directory components or component sequences, excluded anywhere; empty disables |
| `AV_FULL_EVERY` | `7d` | `--now` full-scan interval: seconds or digits with `d`/`h`/`m`; `0` makes every automatic scan full |
| `AV_SCAN_MEMORY_HIGH` | `2G` | rendered scan unit's `MemoryHigh`; digits with optional `K`/`M`/`G`/`T`, or `infinity`; empty omits |
| `AV_SCAN_MEMORY_MAX` | `3G` | rendered scan unit's `MemoryMax`; same syntax; empty omits |
| `AV_EXCLUDE_FSTYPES` | `autofs cifs smb3 smbfs nfs nfs4 9p ceph glusterfs afs fuse fuse.*` | skip these filesystem types (shell patterns); empty disables |
| `AV_MOUNTINFO` | `/proc/self/mountinfo` | mount table read at each scan, without probing mounts |
| `AV_SCAN_TIMEOUT` | `12h` | scanner time limit; `0` disables; kill grace is 5 minutes |
| `AV_POWER_SUPPLY_DIR` | `/sys/class/power_supply` | power-supply class; override only for synthetic tests |
| `AV_POWER_POLL_INTERVAL` | `1` | seconds between runtime power checks; tests use a shorter interval |
| `AV_ONACCESS_PATHS` | scan paths (never `/`) | what real-time scanning watches |
| `AV_ENGINE` | `auto` | `auto` \| `clamdscan` \| `clamscan` |
| `AV_LOG_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/linux-av` | logs + state |
| `AV_QUARANTINE` | `$AV_LOG_DIR/quarantine` | where `-q` moves infected files |
| `AV_CLAMD_SOCKET` | auto-detected | packaged local socket override; arbitrary/remote sockets are refused |
| `AV_ON_FOUND` | – | shell command run when threats are found (alert hook) |
| `AV_TIMER_NAME` | `linux-av-scan` | basename of the installed systemd units |
| `AV_TIMER_BOOT_DELAY` | `1min` | `OnBootSec` for the scan/rootkit timers (run after each boot) |
| `AV_AIDE_BOOT_DELAY` | `15min` | `OnBootSec` drop-in for the AIDE check timer |
| `AV_QUIET_REPORTS` | `1` | `0` leaves chkrootkit's, AIDE's and rkhunter's mail settings alone (otherwise, with no `mail` or `sendmail` on `PATH`, their reports go to the journal and logs) |
| `AV_RKHUNTER_DAILY` | `1` | `0` leaves rkhunter's nightly run and weekly update as the package has them |
| `AV_AIDE_INIT` | `1` | `0` skips the AIDE baseline and the periodic-check enablement (and wins over `av-setup enable --keep-aide-baseline`) |
| `AV_AIDE_INIT_TIMEOUT` | `4h` | `RuntimeMaxSec` of the baseline unit (systemd stops a longer build) |
| `AV_AIDE_INIT_UNIT` | `linux-av-aide-init` | name of the baseline unit |
| `AV_ROOT` | empty | path prefix for the `/etc` and `/var` paths `enable` edits; for tests only; refused (exit 1) when running as root |

A local disk mounted inside a network mount is skipped with it: reaching that disk
requires path lookups through the network mount. A local disk covering a network
or autofs entry at the same mount point is scanned instead, since only the top
mount counts.

`clamscan` cuts a path to 512 characters before matching `--exclude-dir`, so a
deeper mount point is not excluded. Set `AV_EXCLUDE_FSTYPES=` to scan network
mounts on purpose.

`av-scan --now` runs a full scan initially and whenever the last completed full
scan is at least `AV_FULL_EVERY` old. Between full scans it walks regular files,
selecting mtime or ctime newer than the last completed scan. Use
`--changed --now` or `--full-scan --now` to force a mode for the selected paths;
`--full` continues to select `/`. The log records the mode and reason.
`--scheduled` keeps running full scans.

Changed scans prune `AV_EXCLUDE_DIRS`, excluded mounts/filesystem types, and
`AV_EXCLUDE_PATTERNS` before descending. Scratch names match complete components:
`target` skips `/x/target/`, while keeping `/x/targets/` and `/x/mytarget/`.
Regex metacharacters in scratch names are literal. Full clamscan scans use the
same scratch expressions as `--exclude-dir` arguments. Scratch exclusions switch
clamdscan to clamscan when available; otherwise a warning reports the limitation.

Changed scans keep ordinary filenames in a private, temporary newline-delimited
`--file-list` under `AV_LOG_DIR`. Names containing LF (newline) or CR (carriage
return), or measuring **1022 through 4095 bytes** under `LC_ALL=C`, instead travel
through a private NUL-delimited stream into individually quoted clamscan
arguments. ClamAV 1.5.4's file-list reader uses `fgets` with a 1024-byte buffer;
longer lines can split into separate targets, including relative paths. This
avoids line splitting (FAULT-0005 and FAULT-0006) and possible CR stripping;
names stay literal. ClamAV NUL-list support is not
required. Paths measuring **4096 bytes or more** take neither route: clamscan
cannot open them through either route (PATH_MAX). Each of the first 20 is logged
as unscannable with its byte length and a safely quoted 80-byte prefix, then the
total count. Other files still scan, including ordinary batch-mates; the run
returns 2 (or the scanner's stop status, 124, 137 or 143) and holds both stamps
even if a threat is found. Threat reporting and `AV_ON_FOUND` still run. This also keeps
individual argv strings well below MAX_ARG_STRLEN (FAULT-0018).
Argument batches hold up to 1 MiB of argv each, so long names no longer multiply
database loads (FAULT-0017): a name counts its bytes under `LC_ALL=C`, its NUL and
its 8-byte pointer, and a batch ends once it reaches its bound, the name that reaches
it included. The bound is the smaller of 1048576 and half of `getconf ARG_MAX`
(OC-T-0111). On Linux ARG_MAX is a quarter of the stack limit, 2 MiB at the default
8 MiB stack, so the bound is 1 MiB there and the other half is left to the options
and the environment; a stack limit under 4 MiB lowers the bound with it. The
environment's own size is not subtracted. Where getconf is missing or prints no
number, the bound is 1048576. A batch that the kernel still refuses (E2BIG, status
126) is an error that holds both stamps.
All scanner invocations run inside one `timeout`, so `AV_SCAN_TIMEOUT` bounds the
whole worker, not each run.
An earlier batch error cannot be erased by a later clean batch. The batch merge
reports status 1 if any batch finds a threat, so the run reports `THREATS FOUND`
and invokes `AV_ON_FOUND`, while any batch error holds both
stamps and, unless the vanished-file rule below forgives it, logs that the next run
will retry (FAULT-0016). A private pending
marker is created before the worker starts and removed only if no run, the ordinary
list's included, returned above 1. It preserves this distinction independently of the
merged reporting status.
Each scanner run of that worker tees its output into a private copy of its own
beside the combined stream, and the worker leaves the status of every run in one
list (FAULT-0019). When the merged status is 2, the vanished-file rule of
MASTER.md judges the runs one by one, so several runs, each with its own summary,
no longer fail it. Every run's status must be 0 or 2, so a run that failed
outright (E2BIG, SIGKILL) beside one that only lost files, a copy that could not
be written or a missing list forgives nothing. Each copy must hold exactly one
summary, with `Infected files: 0` and, for a run of status 2, at least one
vanished-file entry and a `Total errors` (0 when the line is absent) equal to that
run's old-form warnings alone (a run of status 0 lists none and prints no other
line). The worker's own `ERROR: clamscan batch failed` line goes
to the output and the log but not into a copy, so it is never read as a scanner
error; a forgiven batch of status 2 still leaves that line behind. Forgiven or not,
the run holds both stamps.
A vanished-file entry is either the old form,
`WARNING: Can't open file <path>: No such file or directory`, which ClamAV counts in
`Total errors`, or, since OC-T-0118, a pair. ClamAV 1.5.4 prints a pair for a listed
file that is gone before it reaches it (in `--file-list` mode and argv mode alike) and counts it in no total:
the line `<path>: No such file or directory` and, on the very next line,
`WARNING: <path>: Can't access file`. The second line must be that line exactly, with
the same path, compared as a string and never as a pattern made from the path, so
names holding `[`, `*`, `?` or `\` mean only themselves. A first line alone, a second line
alone, a pair with any line between (a blank one too), a pair naming two paths and a
first line that ends a run are refused, and nothing is forgiven. The path of a
pair goes through every guard of an old-form path (absolute, under a kept scan path,
not at or under a skipped mount, no `.`, `..` or `//` segment) and into the same
absence probe under its 60 s KILL limit: no link along the way, real parent folders,
the path absent. A pair offsets no error: only old-form warnings count against
`Total errors`, so an unreadable file hidden behind pairs raises the total above the
old-form count and the run keeps its error. A gone name with a newline splits both
lines at it, so it matches no pair and the run keeps its error as before. A status 1
run still alerts; pairs never forgive it.
`AV_SCAN_TIMEOUT` stops the worker's whole process group with TERM, and each run's
tee is in it. The tee ignores TERM, HUP and INT, so a `FOUND` line still in the pipe
at that moment reaches the combined stream once clamscan has closed it, and the
stopped run still alerts. The worker has no TERM handler and dies of the signal, so
`timeout` returns at once (124) and never sends the KILL it keeps for the 5-minute
grace; nothing takes the tee. The residual is a clamscan that survives TERM: the
worker is gone, but that clamscan and its tee keep the pipe open, and av-scan waits
for them until clamscan ends or systemd's `TimeoutStartSec` stops the unit
(`root-install.sh` sets 12h30min on OVH; `systemd/av-scan.service` sets none).
os-config is probing whether real clamscan ever does that (OC-T-0113).
The reporting priority matches
[ClamAV 1.5.4's `scanmanager` rule](https://github.com/Cisco-Talos/clamav/blob/clamav-1.5.4/clamscan/manager.c#L1883-L1892),
which selects infection before errors. Temporary lists and captured output are
removed on exit.

The walk uses GNU find's `-ignore_readdir_race`. If find still exits non-zero,
the scan processes everything it listed, logs **partial walk**, returns an error
(2 unless the scanner returned another error), and leaves both stamps unchanged.
Keeping the stamps ensures the next run retries files that the incomplete walk
may have missed; the error is never silently forgiven. Threat reporting and
`AV_ON_FOUND` still run if the partial walk's scanner finds a threat.
With clamdscan selected, changed mode uses clamscan when available, otherwise it
logs a fallback to a full clamdscan scan. An empty successful walk logs
`nothing changed` and advances the good-scan stamp without invoking the scanner.

`AV_LOG_DIR/last-good-scan.stamp` and `last-full-scan.stamp` record scan **start**
times, preserving eligibility for files changed during a scan. Stamps advance
only after the report is written and every scanner batch completes with 0
(clean) or 1 (found). Any batch error holds both stamps, including a threat plus
an error whose merged reporting status is 1. Unscannable paths, partial walks,
timeouts, signals, and forgiven vanished-file errors also leave stamps alone.
A clamscan summary reporting `Total errors` above zero holds both stamps even
when its exit status is 1 because it also found a threat. Under `--now`, clamscan
threat output captured before `AV_SCAN_TIMEOUT` stops the scan, or before the
scanner alone is killed, still triggers `THREATS FOUND` and `AV_ON_FOUND`; the
stop status (124, 137 or 143) is preserved. This does not cover stopping the
whole service unit with SIGTERM or `--scheduled` runs. Output is searched only
after such a stop: a run that ends with status 0 or 2 alerts on status alone, so a
`FOUND` line in its output, which a file name holding a newline can forge inside
clamscan's own warning, raises no alert. A changed scan with odd names holds that
rule run by run (OC-T-0112): the merged status keeps only the first error, so a run
killed after an earlier run returned 2 would hide behind that 2. The worker's list
gives every run's own status, and a run of 124 or above has its own output searched
even when the merged status is 2. When the merged status is itself 124 or above, the
whole output is searched, other runs' text included. The clamdscan engine
alerts on exit status 1; it does not recover threats from interrupted output.
Unscannable-path diagnostics log the first 20 paths and then the total count
when there are more. Under `--now`, failures returned by the scan or stamp
writes close with an error line; incomplete walks never report clean.
Deleting both stamps requests a new full scan. Use a separate `AV_LOG_DIR` for
independent scan path sets so their histories do not share stamps.

Re-run `--install-timer` after changing either memory setting. Invalid sizes fail
before either unit is written. The scan unit also sets `CPUQuota=100%` and
`CPUWeight=20`, with `Nice=10` and `IOSchedulingClass=idle`.

For OVH, `root-install.sh` installs
`/etc/systemd/system/linux-av-scan.service.d/limits.conf` atomically as root:root
0644 with only `MemoryHigh` and `MemoryMax`, then calls `systemctl daemon-reload`.
OVH's existing `R-3377-cpu-cap.conf` remains the sole CPU drop-in, setting
`CPUWeight=20` and `CPUQuota=100%` (FAULT-0020). Keeping CPU settings there
preserves the host's established control without a later override from
`limits.conf`. Fresh hosts using `--install-timer` still receive CPU settings
from `systemd/av-scan.service`.
Because the installer writes no CPU setting, it first checks that
`R-3377-cpu-cap.conf` is still as OVH needs it: a regular file (not a link),
owned by root, not writable by group or others, with `CPUQuota=` and
`CPUWeight=` lines that carry a value. Otherwise it stops before it renders,
keeps or writes anything, and says which check failed (OC-T-0083). After the
reload it prints `systemctl show` for `TimeoutStartUSec`, `CPUQuotaPerSecUSec`,
`CPUWeight`, `MemoryHigh` and `MemoryMax`, so the card shows the bounds systemd
now holds for the scan.
The installer never enables, starts or restarts
units and leaves the timer state alone (R-3377). Starting remains a separate
card; do not restart the scan as part of this build or install.

**The legacy guard on OVH's two root units (OC-T-0037).** Its default mode remains
compatible with those run cards. The `--power` mode used by the permanent launcher
also checks all installed toolkit commands, libraries and templates, the sole
root config, inventory, managed unit/drop-in paths, daily cron originals and
runtime state (including ancestors); user/repo config is never selected.

 `linux-av-scan.service` and `linux-av-rootkit.service` run as
root, so they must never run or source a file a user can change. OVH's drop-in `root-owned.conf` already points
`ExecStart` at the root-owned copy in `/usr/local/lib/linux-av`, but the base unit files still named
`/usr/local/bin/av-scan`, a link into a checkout a user can write (losing the drop-in fell back to it), and nothing
checked ownership at start. `root-install-guard.sh` closes both, run as root by `/usr/local/sbin/ovh-root-run` from a
run card. Its one `# sha256` line pins `bin/av-guard`; the runner checks it, and so does the installer, before it writes
anything.

- `bin/av-guard` is installed root:root 0755 as `/usr/local/lib/linux-av/bin/av-guard` and run as `ExecStartPre=` by a
  new drop-in, `05-guard.conf`, in each unit's `.d` folder. It prints one line, `av-guard: <path>: <reason>`, and exits
  1 (the unit fails to start) unless every component from `/` down to each target is not a link, is owned by uid 0 and
  is not writable by group or others. The targets are: the guard itself; `bin/av-scan` and `lib/common.sh` of the
  installed copy; each config file `av-scan` would source, if it exists (`/etc/linux-av/av.env`,
  `/root/.config/linux-av/av.env`, `/usr/local/lib/linux-av/config/av.env`; a missing one is allowed, but the folders
  above it that exist are still checked, so nobody else can create it); both unit files in `/etc/systemd/system`; and
  both drop-in folders with every entry in them (dot files and links too; a folder inside is checked, not entered,
  because systemd reads only the files directly in a drop-in folder). Any other missing target refuses. It reads no
  argument, file or environment variable and sets its own `PATH`; names with spaces or newlines are safe (a newline
  shows as `\n` so the refusal stays one line). It does not check ACLs or extended attributes, or units under `/run`
  and `/usr/lib` (only root writes there).
- The installer rewrites each base unit file so `ExecStart` names `/usr/local/lib/linux-av/bin/av-scan --now`
  (`--rootkit` for the rootkit unit), changing no other byte; the old file is kept once as
  `<unit>.before-OC-T-0037`. `root-owned.conf` and the `/usr/local/bin/av-scan` link stay as they are, and
  `bin/av-scan` and `lib/common.sh` do not change.
- It refuses, writing nothing, if its pin does not match; if the folders it writes into (`/usr/local/lib`,
  `/usr/local/lib/linux-av`, its `bin`, `/etc/systemd/system` and both drop-in folders) or the two unit files are
  links, are not owned by root or are group- or other-writable; if a file it would write is a link or not a regular
  file; or if a unit's `ExecStart=` line is not the old line or the new one. Then `systemctl daemon-reload`; a
  read-back of `ExecStartPre` and `ExecStart` of both units, refused unless systemd holds the guard (errors not
  ignored) and `av-scan` with its argument; and one run of the installed guard, so the card shows at once whether this
  host passes it. It starts, stops, enables, disables and restarts nothing, and a second run writes the same bytes and
  keeps the first backups.

`av-scan --render-scan-limits` renders that drop-in without installing or
activating anything. It shares memory defaults/validation with `--install-timer`
and renders only the template's memory directives. The installer pins config
selection to an empty private file for
predictable defaults; explicit `AV_SCAN_MEMORY_HIGH`/`AV_SCAN_MEMORY_MAX`
environment overrides remain available. Its `# sha256` manifest pins all three
rendering inputs (`bin/av-scan`, `lib/common.sh`, `systemd/av-scan.service`), and
installation prints the generated drop-in's SHA-256 alongside the installed
script/library hashes.

Round 3 closes the long-name remainder of FAULT-0006, FAULT-0016 and FAULT-0020.
The new long-name, mixed-result and memory-only installer regressions fail at
`0d5499d`; mutants check the length boundary, byte counting, batch precedence
and duplicate CPU settings. Round 4 fixes round 3's held-stamp regression for
threat-plus-error batches and bounds long names at 4096 bytes (FAULT-0018).
The stamp assertions and unscannable-path regression fail at `c1f08de`; mutants
remove the stamp hold, remove or raise the path bound, count characters instead
of bytes, and remove the forced error status. FAULT-0017, FAULT-0019 and
FAULT-0021 remain unchanged, including the existing memory limits and OVH CPU
drop-in dependency.
OC-T-0080 batches the odd names by bytes (FAULT-0017) and re-checks FAULT-0018:
`scan_path_scannable` refuses every path of 4096 bytes or more before either
route, so no argv string comes near MAX_ARG_STRLEN (131072), and a batch holds
about 1 MiB. The unscannable-path regression, with its 131072-byte name, and its
mutants still pin that bound. The new batch regression fails at `d158e91`, where
names of 4000 bytes ran 3 to a batch; mutants restore that commit's limits, drop
the NUL and pointer, count characters and leave the helper out of the worker.
OC-T-0081 lets the vanished-file rule judge a worker's runs one by one (FAULT-0019).
The two forgiveness regressions fail at the commit before it: there a batch of
status 2 returned at the pending marker before the rule ran, and the runs'
summaries would have failed it. The regression for errors that must stay unforgiven
passes there too, since nothing was forgiven; only mutants pin it, each forgiving
one more case: any status accepted, a failed tee, a run's stderr dropped, a clean
run left unchecked, a run's status ignored when its total is read, and a total no
longer compared with its own run's warnings. Other mutants restore the early
return, parse the combined stream, drop the status list and take the status from tee.
OC-T-0111, OC-T-0112 and OC-T-0114 close the Lows the two seats left on that work.
OC-T-0111 bounds a batch by the exec limit: one regression stubs getconf and a scanner
that refuses an over-long argv as the kernel does, another runs the real getconf on a
4 MiB soft stack, and mutants remove the lowering, its halving, the 1 MiB cap, the check
for a number, the silenced stderr and the name asked for. OC-T-0112 searches the output
of a run the worker records as stopped (124 or above) though an earlier run's 2 is the
merged status; mutants drop the search, lower its threshold to 2, search the whole
output in place of the run's own copy and skip the check for a number. OC-T-0114 orders
the regression of the tee's ignored signals by cause (a marker the scanner's TERM trap
writes, which the stub tee waits for), and `batch_tee_signals_unguarded` still kills it.
Round 2 leaves FAULT-0008 through FAULT-0015 open and otherwise preserves round 1.
The LF, CR/plain-twin, partial-walk and installer regressions fail at `22f338a`;
`tests/run.sh` also checks bounded batches, a shared timeout and retained errors.
The scanner and test harness already require Bash; `root-install.sh` remains
POSIX sh. On a host where `sh` is Dash, use Bash to parse/run those existing Bash
files (`bash -n bin/av-scan`, `bash tests/run.sh`, `bash tests/mutants.sh`).

`av-setup` installs and enables auditd, but deliberately does **not** invent an
audit policy. Add host-specific rules under `/etc/audit/rules.d/` and verify
them with `auditctl -l`; an active daemon with `No rules` records no useful
policy events.

## 6. Cross-distro reference (the differences, in one place)

| Thing | Arch | Debian | Ubuntu |
|---|---|---|---|
| Package manager | `pacman -S` | `apt install` | `apt install` |
| ClamAV package(s) | `clamav` | `clamav clamav-daemon clamav-freshclam` | same as Debian |
| AIDE package(s) | `aide` | `aide aide-common` | `aide aide-common` |
| auditd package | `audit` | `auditd` | `auditd` |
| chkrootkit | **AUR** | `apt install chkrootkit` | `apt install chkrootkit` |
| clamd / freshclam / auditd units | manual `enable --now` | auto-enabled on install | auto-enabled on install |
| Seed DB before clamd starts | **required** (`freshclam`) | automatic | automatic |
| AIDE init command | `aide --init` | `aideinit` | `aideinit` |
| AIDE DB path | `/var/lib/aide/aide.db.gz` (gzipped) | `/var/lib/aide/aide.db` | `/var/lib/aide/aide.db` |
| AIDE check binary | `aide` | `aide.wrapper` | `aide.wrapper` |
| AppArmor | opt-in (kernel cmdline + reboot) | on by default | on by default |
| Config paths (same!) | `/etc/clamav/clamd.conf`, `/etc/clamav/freshclam.conf` | same | same |
| clamd user / DB dir (same!) | `clamav` / `/var/lib/clamav` | same | same |

`av-scan` and `av-setup` already branch on all of these for you via
`av_detect_distro` in `lib/common.sh` — the table is here so you know *why*.

## 7. Uninstall

Deleting the user checkout leaves the permanent root installation intact.
To uninstall the toolkit, remove the persistent power policy first: disable
and stop `linux-av-power.service`, restore each managed daily cron wrapper from
its `.linux-av-power-original` (after verifying the wrapper marker), remove the
guardian unit, `40-linux-av-power.conf` drop-ins and `/etc/linux-av/power.units`,
then run `systemctl daemon-reload`. Scanner services bound to the guardian stop
with it; restore any services you intend to retain explicitly. The inventory
above names every managed path, including custom scan unit basenames.

```bash
sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --remove-timer          # drop the systemd timer
rm ~/.local/bin/av-scan ~/.local/bin/av-setup ~/.local/bin/av-aide-arch   # or /usr/local/bin with sudo
# packages stay installed; remove with pacman -Rns / apt purge if you want them gone
```

## 8. Requirements & notes

- **bash 4+, systemd, coreutils, util-linux (`flock`)** — present on all three distros by default.
- `av-setup` needs **root** (re-execs via `sudo`); `av-scan --now/--scheduled`
  only needs enough rights to read the paths you scan.
- ClamAV exit codes are handled: `0` clean, `1` **threats found** (logged, not a
  crash), `2` scanner error, `124` scan timed out, `137` killed after timeout.
- Logs go to `$AV_LOG_FILE` (default under `~/.local/state/linux-av/`).

## 8.1 Installing AIDE on Arch (`av-aide-arch`)

On **Debian/Ubuntu**, AIDE is a normal repo package — `av-setup install` pulls
`aide aide-common` with `apt`, done. **Arch is different**: AIDE is AUR-only and
its 0.19.x release won't compile against `nettle >= 3.10` (the
`nettle_hash_digest_func` signature dropped its `length` argument), failing with:

```
src/md.c:169: too many arguments to function '...digest'; expected 2, have 3
```

AIDE also supports **libgcrypt**, whose code path is unaffected. The bundled
`av-aide-arch` script fetches the AUR PKGBUILD, forces the crypto backend to
gcrypt, and builds it:

```bash
av-aide-arch              # fetch → patch (--without-nettle --with-gcrypt) → makepkg → install
av-aide-arch --rebuild    # force a clean rebuild
```

Verify: `aide --version` runs and `ldd "$(command -v aide)" | grep gcrypt` shows
`libgcrypt.so`. Then `sudo /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan --integrity` works. AIDE is optional — the
ClamAV / rkhunter / chkrootkit / auditd stack is fully functional without it.

### How the makepkg build differs from an `apt`/`pacman` install

| Aspect | `apt`/`pacman` (repo package) | `makepkg` (AUR, what `av-aide-arch` does) |
|---|---|---|
| Runs as | root (`sudo apt/pacman`) | **your normal user** — `makepkg` *refuses* to run as root; it calls `sudo` itself only for the final install |
| Source | prebuilt binary package | **downloads source + compiles locally** from a PKGBUILD |
| Toolchain | none needed | needs `base-devel` + `git` installed |
| Trust | distro-signed package | PKGBUILD from the AUR — *read it first*; makepkg verifies the upstream tarball's PGP signature |
| Customization | none | we edit the PKGBUILD's `./configure` to add `--without-nettle --with-gcrypt` |
| Flags used | — | `makepkg -sif` → `-s` install build deps, `-i` install the result, `-f` overwrite a stale build |
| Result | package + auto-enabled services (Debian) | a `.pkg.tar.zst` that pacman installs; **no service is auto-enabled** (Arch never does) |

`av-aide-arch` prefers your AUR helper (`paru -G` / `yay -G`) to fetch the
PKGBUILD and falls back to a direct `git clone` of the AUR repo. Override the
build dir with `AV_AIDE_BUILD_DIR` (default `~/.cache/linux-av`).

### `aide.wrapper` and scheduling — per distro

`aide.wrapper` is a **Debian/Ubuntu-only** helper (from `aide-common`): Debian
splits AIDE's config into `/etc/aide/aide.conf` + fragments under
`/etc/aide/aide.conf.d/`, and `aide.wrapper` assembles them and calls the real
`aide --config …`. So on Debian you run `aide.wrapper --init|--check|--update`;
on **Arch there is no wrapper** — `aide` reads a single `/etc/aide.conf`. It is a
command, not a service — nothing to "enable". `av-scan --integrity` picks the
right one automatically.

The *scheduled* daily check differs too, and `av-setup enable` turns it on for you:

| | Arch (AUR) | Debian / Ubuntu (`aide-common`) |
|---|---|---|
| Runner | `aide --check` | `aide.wrapper --check` |
| Schedule unit | `aidecheck.timer` (daily 05:00, `ConditionACPower=true`) | `dailyaidecheck.timer` or `/etc/cron.daily/aide` (per release) |
| Enable | `sudo systemctl enable --now aidecheck.timer` | usually auto-enabled by the package; else enable the timer / set `CRON_DAILY_RUN=yes` in `/etc/default/aide` |
| Init DB | `aide --init` → move to `/var/lib/aide/aide.db.gz` | `sudo aideinit` |

`av-setup enable` runs that init command in its own systemd unit (see "Where the reports go"), not in your terminal.

Those packaged timers fire at a fixed clock time, so a box that's powered off then
never runs the check. `av-setup enable` drops in
`/etc/systemd/system/<timer>.d/10-linux-av-bootdelay.conf` adding
`OnBootSec=$AV_AIDE_BOOT_DELAY` (default 15 min) + `Persistent=true`, so the AIDE
check also runs after every boot and catches up a missed run — matching the
scan/rootkit timers.

## 9. License

MIT — see [LICENSE](LICENSE).
