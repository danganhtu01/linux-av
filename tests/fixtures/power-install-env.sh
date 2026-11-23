# Sourced by unprivileged, inert installer fixtures with T and REPO set.
R=$T/root; B=$T/tools; L=$R/usr/local/lib/linux-av
export R B L
mkdir -p "$B" "$R/run" "$R/proc/1/fd" "$R/etc/cron.daily" "$R/etc/systemd/system" "$T/release" "$T/home"
: > "$R/proc/1/cmdline"
cp -r "$REPO/bin" "$REPO/lib" "$REPO/systemd" "$T/release/"
cp "$REPO/tests/fixtures/policy-systemctl" "$B/systemctl"
cat > "$B/stat" <<'STUB'
#!/bin/bash
set -eu
# Only ownership is simulated; real file modes and types remain observable.
if [ "$1" = -c ]; then
    fmt=$2; path=${@: -1}
    case $path in /home/atdang/*) : > "$R/forbidden-probe"; exit 99 ;; esac
    owner=0
    if [ -f "$R/stat-foreign" ] && [ "$(cat "$R/stat-foreign")" = "$path" ]; then owner=1000; fi
    case $fmt in
        '%u %A') printf '%s %s\n' "$owner" "$(/usr/bin/stat -c %A "$path")"; exit ;;
        '%u %a') printf '%s %s\n' "$owner" "$(/usr/bin/stat -c %a "$path")"; exit ;;
        '%u %g %a') printf '%s 0 %s\n' "$owner" "$(/usr/bin/stat -c %a "$path")"; exit ;;
    esac
fi
exec /usr/bin/stat "$@"
STUB
# The installer ancestor walk sees a simulated root-owned private tree. /tmp's
# real writable bit is excluded only for this enclosing fixture ancestor.
python3 - <<'PY'
import os
p=os.environ['B']+'/stat'
s=open(p).read().replace('fmt=$2; path=${@: -1}', '''fmt=$2; path=${@: -1}
    if [ "$path" = /tmp ] && [ "$fmt" = '%u %A' ]; then echo '0 drwxr-xr-x'; exit; fi
    if [ "$path" = /tmp ] && [ "$fmt" = '%u %a' ]; then echo '0 755'; exit; fi''')
open(p,'w').write(s)
PY
cat > "$B/install" <<'STUB'
#!/bin/bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
    case $1 in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec /usr/bin/install "${args[@]}"
STUB
printf '#!/bin/sh\necho 0\n' > "$B/id"
printf '#!/bin/sh\necho fixture\n' > "$B/hostname"
printf '#!/bin/sh\nexec /bin/sleep 0.02\n' > "$B/sleep"
cat > "$B/readlink" <<'STUB'
#!/bin/bash
for arg in "$@"; do
    case $arg in /home/atdang/*) : > "$R/forbidden-probe"; exit 99 ;; esac
done
exec /usr/bin/readlink "$@"
STUB
cat > "$B/sync" <<'STUB'
#!/bin/sh
if [ -f "$R/sync-failure" ]; then
    case $2 in */cron-migration/*/.linux-av.*) echo 'injected archive sync failure' >&2; exit 96 ;; esac
fi
exec /usr/bin/sync "$@"
STUB
chmod +x "$B"/*
# Explicit test-only relocation/identity substitutions; no production test knobs.
python3 - <<'PY'
import os, re, hashlib
T,R,B,L,repo=(os.environ[x] for x in ('T','R','B','L','REPO'))
s=open(repo+'/bin/av-guard').read().replace('base=\n','base='+R+'\n').replace('proc=/proc\n','proc='+R+'/proc\n')
s=s.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH='+B+':/usr/bin:/bin')
open(T+'/release/bin/av-guard','w').write(s)
s=open(repo+'/lib/root-policy.sh').read().replace('$EUID','0').replace('local action=${1:?} base=','local action=${1:?} base='+R)
s=s.replace('[ "$AV_HOME" = /usr/local/lib/linux-av ]','[ "$AV_HOME" = '+L+' ]')
# Only literal host writes/checks move. Canonical paths in generated policy and
# manifests stay unchanged, as do all $base-relative paths.
for old,new in [
 ('sound /run/linux-av-policy.lock','sound '+R+'/run/linux-av-policy.lock'),
 ('-ef /run/linux-av-policy.lock','-ef '+R+'/run/linux-av-policy.lock'),
 ('>>/run/linux-av-policy.lock','>>'+R+'/run/linux-av-policy.lock'),
 ('-e /run/linux-av-policy.lock','-e '+R+'/run/linux-av-policy.lock'),
 ('-f /run/linux-av-policy.lock','-f '+R+'/run/linux-av-policy.lock'),
 ('sound /etc/linux-av/power.incomplete','sound '+R+'/etc/linux-av/power.incomplete'),
 ('-e /etc/linux-av/power.incomplete','-e '+R+'/etc/linux-av/power.incomplete'),
 ('-f /etc/linux-av/power.incomplete','-f '+R+'/etc/linux-av/power.incomplete'),
 ('0755 /etc/linux-av','0755 '+R+'/etc/linux-av'),
 ('> /etc/linux-av/power.incomplete','> '+R+'/etc/linux-av/power.incomplete'),
 ('rm -f /etc/linux-av/power.incomplete','rm -f '+R+'/etc/linux-av/power.incomplete'),
 ('sync -f /etc/linux-av','sync -f '+R+'/etc/linux-av')]:
    s=s.replace(old,new)
open(T+'/release/lib/root-policy.sh','w').write(s)
s=open(repo+'/root-install-power.sh').read()
for path in ('/usr/local/lib/linux-av','/etc','/run'):
    s=s.replace(path,R+path)
s=s.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin','PATH='+B+':/usr/bin:/bin')
s=s.replace('/bin/sh "$dst/bin/av-root" av-setup power-policy','/bin/bash "'+T+'/policy-driver"')
def pin(m):
    rel=m.group(2)
    return '# sha256 '+hashlib.sha256(open(T+'/release/'+rel,'rb').read()).hexdigest()+' '+rel
s=re.sub(r'^# sha256 ([a-f0-9]{64}) (.*)$',pin,s,flags=re.M)
open(T+'/installer','w').write(s)
PY
cat > "$T/policy-driver" <<'DRIVER'
set -euo pipefail
# Match av-root's log destination inside the fixture; include it in snapshots.
export AV_HOME="$L" AV_ROOT= AV_CONFIG="$T/empty-config" AV_LOG_DIR="$R/var/log/linux-av" AV_COLOR=never
unset AV_LOG_FILE
# Use the real read-only entrypoint, including its stderr-only refusal path.
if [ "${1:-}" = verify ]; then
    exec /bin/bash "$L/bin/av-setup" power-policy-verify
fi
. "$L/lib/common.sh"
. "$L/lib/root-policy.sh"
av_power_policy "${1:-install}"
DRIVER
: > "$T/empty-config"
export PATH="$B:/usr/bin:/bin" POLICY_FIXTURE_ROOT="$R"
