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
# from a checkout you already have:
./bootstrap.sh --full --timer 86400000

# from scratch on a fresh box (clones first):
REPO_URL=<remote>/linux-av.git ./bootstrap.sh --system --full --onaccess --timer 86400000
```

`--full` scans the **whole box** (see §4.1); omit it to scan only `$HOME`.
`--system` installs for all users, `--onaccess` enables ClamAV real-time
protection, and `--timer <ms>` adds a persistent daily-ish timer. The rest of
this README explains what it does and how to drive `av-scan` by hand.

---

## 1. Layout

```
linux-av/
├── bin/
│   ├── av-scan          # scan runner: --now / --scheduled <ms> / timers / rootkit / integrity
│   └── av-setup         # installs packages + enables services per distro
├── lib/
│   └── common.sh        # distro detection, path/env resolution, logging (sourced by both)
├── systemd/
│   ├── av-scan.service  # templates rendered by `av-scan --install-timer`
│   └── av-scan.timer
├── config/
│   └── av.env.example   # every tunable, with defaults — copy to av.env
└── install.sh           # symlinks the two tools onto your PATH
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
the already-enabled services are up. Either way you end up in the same place.

### Real-time (on-access) scanning — optional
```bash
av-setup onaccess   # appends OnAccess* to /etc/clamav/clamd.conf, enables clamav-clamonacc
```
Not on by default anywhere. It watches `AV_ONACCESS_PATHS` (default: your scan
paths, but **never `/`** — on-access can't watch the whole root fs, so it falls
back to `/home`) and blocks access to infected files. It also auto-adds the
`OnAccessExcludeUname` directive that clamonacc *requires* (excluding the
scanner's own user) to avoid an infinite scan loop. Narrow it with
`AV_ONACCESS_PATHS='/home /srv'`.

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
Force it with `--engine clamscan` or `AV_ENGINE=`.

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

## 9. License

MIT — see [LICENSE](LICENSE).
