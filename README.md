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
git checkout works for any user on any of the three distros without editing a
line.

---

## 0. Fastest path — `bootstrap.sh`

Run this **on each box**; it clones (if needed), installs the commands, installs
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
│   └── av.env.example     # every tunable, with defaults — copy to av.env
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
> chmod +x ~/linux-av/bin/av-scan ~/linux-av/bin/av-setup
> ln -s ~/linux-av/bin/av-scan  ~/.local/bin/av-scan
> ln -s ~/linux-av/bin/av-setup ~/.local/bin/av-setup
> ```
> Symlinking (not copying) means `git pull` updates every box in place.

## 3. Install + enable the AV stack

```bash
av-setup all        # = av-setup install  +  av-setup enable   (re-execs via sudo)
av-setup status     # what's installed / running
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
not actually active. It also provisions the runtime directories
advertised by Ubuntu's packaged `clamav-clamonacc.service` (including its
quarantine and log locations) and adds log rotation for the packaged on-access
log when no existing policy covers it. Either way you end up in the same place.

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
automatically switches to `clamscan`; narrower scans still prefer the daemon.
Force either engine with `--engine clamscan|clamdscan` or `AV_ENGINE=`.

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
sudo av-scan --full --now            # entire filesystem, as root
sudo AV_SCAN_PATHS=/ av-scan --now   # same, via env
```

What a root `--full` scan **does** and **does not** cover:

- ✅ **Other users' home directories** — yes, when run as root.
- ✅ **Mounted drives** (USB, extra disks, bind mounts) — yes; ClamAV crosses
  filesystem boundaries by default, so anything mounted under `/` at scan time is
  included.
- ⚠️ **Network mounts** (NFS/SMB) — also included, and can be *very* slow. Skip
  them by adding their mountpoints to `AV_EXCLUDE_DIRS`.
- ❌ **Unmounted / disconnected drives** — a scan only sees what's mounted when
  it runs. Mount it first, or scan explicitly: `sudo av-scan --path /mnt/disk --now`.
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
sudo av-scan --install-timer 86400000   # every 86 400 000 ms = 1 day
sudo av-scan --remove-timer
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
sudo av-scan --install-rootkit-timer 604800000   # every 604 800 000 ms = 7 days
sudo av-scan --remove-rootkit-timer
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
`av.env` is looked up in this order (first found wins): `$AV_CONFIG` →
`~/.config/linux-av/av.env` → `/etc/linux-av/av.env` → `<repo>/config/av.env`.

Key vars (all optional, shown with defaults):

| Var | Default | Meaning |
|---|---|---|
| `AV_SCAN_PATHS` | `$HOME` | what `--now` scans |
| `AV_ONACCESS_PATHS` | scan paths (never `/`) | what real-time scanning watches |
| `AV_ENGINE` | `auto` | `auto` \| `clamdscan` \| `clamscan` |
| `AV_LOG_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/linux-av` | logs + state |
| `AV_QUARANTINE` | `$AV_LOG_DIR/quarantine` | where `-q` moves infected files |
| `AV_CLAMD_SOCKET` | auto-detected | override if detection fails |
| `AV_ON_FOUND` | – | shell command run when threats are found (alert hook) |
| `AV_TIMER_NAME` | `linux-av-scan` | basename of the installed systemd units |
| `AV_TIMER_BOOT_DELAY` | `1min` | `OnBootSec` for the scan/rootkit timers (run after each boot) |
| `AV_AIDE_BOOT_DELAY` | `15min` | `OnBootSec` drop-in for the AIDE check timer |

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

```bash
sudo av-scan --remove-timer          # drop the systemd timer
rm ~/.local/bin/av-scan ~/.local/bin/av-setup   # or /usr/local/bin with sudo
# packages stay installed; remove with pacman -Rns / apt purge if you want them gone
```

## 8. Requirements & notes

- **bash 4+, systemd, coreutils** — present on all three distros by default.
- `av-setup` needs **root** (re-execs via `sudo`); `av-scan --now/--scheduled`
  only needs enough rights to read the paths you scan.
- ClamAV exit codes are handled: `0` clean, `1` **threats found** (logged, not a
  crash), `2` scanner error.
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
`libgcrypt.so`. Then `sudo av-scan --integrity` works. AIDE is optional — the
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

Those packaged timers fire at a fixed clock time, so a box that's powered off then
never runs the check. `av-setup enable` drops in
`/etc/systemd/system/<timer>.d/10-linux-av-bootdelay.conf` adding
`OnBootSec=$AV_AIDE_BOOT_DELAY` (default 15 min) + `Persistent=true`, so the AIDE
check also runs after every boot and catches up a missed run — matching the
scan/rootkit timers.

## 9. License

MIT — see [LICENSE](LICENSE).
