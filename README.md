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
Not on by default anywhere; it watches `$AV_SCAN_PATHS` and blocks-on-detect.

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
