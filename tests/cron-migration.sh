#!/usr/bin/env bash
# Unprivileged inert migration proof. No host services, chroot, sudo or scanners.
# Test copies relocate fixed paths, simulate root metadata and shorten polling;
# the actual installer/disabler/drain/renderer ordering remains under test.
set -euo pipefail
[ "$EUID" != 0 ] || { echo 'cron migration fixtures require an unprivileged user' >&2; exit 2; }
REPO=${AV_REPO_UNDER_TEST:-$(cd "$(dirname "$0")/.." && pwd)}
T=$(mktemp -d)
legacy= opened= policy_job= older= installer=
cleanup() {
    # Inert fixtures finish naturally; the migration never signals them.
    for fifo in "$T"/release-*; do [ ! -p "$fifo" ] || timeout 1 sh -c 'printf "done\n" > "$1"' sh "$fifo" || true; done
    for pid in $legacy $opened $policy_job $older $installer; do wait "$pid" 2>/dev/null || true; done
    [ "${KEEP_CRON_FIXTURE:-0}" = 1 ] || rm -rf -- "$T"
}
trap cleanup EXIT
export T REPO
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
    case $fmt in
        '%u %A') printf '0 %s\n' "$(/usr/bin/stat -c %A "$path")"; exit ;;
        '%u %a') printf '0 %s\n' "$(/usr/bin/stat -c %a "$path")"; exit ;;
        '%u %g %a') printf '0 0 %s\n' "$(/usr/bin/stat -c %a "$path")"; exit ;;
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
export AV_HOME="$L" AV_ROOT= AV_CONFIG="$T/empty-config" AV_LOG_FILE="$T/policy.log" AV_COLOR=never
. "$L/lib/common.sh"
. "$L/lib/root-policy.sh"
av_install_power_policy
DRIVER
: > "$T/empty-config"
export PATH="$B:/usr/bin:/bin" POLICY_FIXTURE_ROOT="$R"
fail() { echo "FAIL cron migration: $*" >&2; [ ! -f "$T/out" ] || cat "$T/out" >&2; exit 1; }
run() { (cd "$T/release" && /bin/sh "$T/installer") > "$T/out" 2>&1; }
route=$R/etc/cron.daily/rkhunter
state=$R/etc/linux-av/cron-migration/rkhunter
placeholder() { grep -qx '# linux-av cron migration disabled' "$route"; }
all_disabled() {
    local name
    for name in rkhunter chkrootkit aide aide-common; do
        grep -qx '# linux-av cron migration disabled' "$R/etc/cron.daily/$name" || return 1
    done
}
await() { for ((n=0;n<500;n++)); do "$@" && return 0; /bin/sleep 0.01; done; fail "await $*"; }
# An exact legacy argv process must outlive replacement and block installation.
# Its content is only a FIFO read; no package or scanner is executed.
printf '#!/bin/sh\n# legitimate new package\nexit 0\n' > "$route"; chmod 0750 "$route"
cp -p "$route" "$T/package"
for name in chkrootkit aide aide-common; do cp -p "$route" "$R/etc/cron.daily/$name"; done
printf '#!/bin/sh\n# legitimate earlier original\nexit 0\n' > "$route.linux-av-power-original"; chmod 0600 "$route.linux-av-power-original"
cp -p "$route.linux-av-power-original" "$T/earlier"
: > "$R/sync-failure"
run && fail 'archive sync failure accepted'
cmp "$route" "$T/package" || fail 'dispatch replaced before durable archive'
cmp "$route.linux-av-power-original" "$T/earlier" || fail 'original changed before durable archive'
[ ! -e "$L" ] || fail 'archive sync failure installed code'
rm "$R/sync-failure"
mkfifo "$T/release-legacy"
/bin/bash -c 'read -r line < "$1"' /etc/cron.daily/rkhunter "$T/release-legacy" & legacy=$!
ln -s "/proc/$legacy" "$R/proc/$legacy"
run & installer=$!
await all_disabled
[ ! -e "$L" ] || fail 'installation preceded drain'
kill -0 "$legacy" || fail 'legacy process was signaled'
wait "$installer" && fail 'timeout accepted legacy work'
grep -q 'timed out draining legacy jobs' "$T/out" || fail 'timeout not explicit'
placeholder || fail 'timeout re-enabled dispatch'
[ ! -e "$L" ] || fail 'timeout installed code'
[ -f "$R/etc/linux-av/power.incomplete" ] || fail 'timeout missing persistent gate'
cmp "$T/package" "$state/pending" || fail 'pending package bytes lost'
[ "$(/usr/bin/stat -c %a "$state/pending")" = 750 ] || fail 'raw mode lost'
for original in "$T/package" "$T/earlier"; do
    found=0
    for saved in "$state"/saved.*; do
        if cmp -s "$original" "$saved" && [ "$(/usr/bin/stat -c '%F %a' "$original")" = "$(/usr/bin/stat -c '%F %a' "$saved")" ]; then found=1; fi
    done
    [ "$found" = 1 ] || fail 'legitimate raw original/metadata not durably archived'
done
# Retry times out the same way; placeholder must never become the original.
rm "$route.linux-av-power-original" # interruption before working-copy publication
run && fail 'retry accepted running legacy job'
cmp "$T/package" "$state/pending" || fail 'retry reclassified placeholder'
cmp "$T/package" "$route.linux-av-power-original" || fail 'retry did not restore missing working original'
kill -0 "$legacy" || fail 'retry killed legacy process'
# Release naturally (no signals), after both bounded timeouts.
printf 'release\n' > "$T/release-legacy"; wait "$legacy"; rm "$R/proc/$legacy"; legacy=
echo 'ok replacement before drain; bounded timeout; preserved type/mode/bytes; disabled retry; no legacy signals'
# Inject readback failure: no guarded route is activated and retry can recover.
printf yes > "$R/override.linux-av-power.service.NeedDaemonReload"
run && fail 'bad effective readback accepted'
placeholder || fail 'readback failure activated routing'
[ -f "$state/pending" ] || fail 'readback failure lost pending recovery'
rm "$R/override.linux-av-power.service.NeedDaemonReload"
run || fail 'timeout/readback recovery failed'
grep -qx '# linux-av mains-only cron wrapper' "$route" || fail 'guarded route not activated'
[ ! -e "$state/pending" ] && [ ! -e "$R/etc/linux-av/power.incomplete" ] || fail 'success retained incomplete state'
cmp "$T/package" "$route.linux-av-power-original" || fail 'recovered package original differs'
# Existing active scheduler behavior: executing the inert placeholder during
# draining produces no payload; policy becomes guarded only after readback.
[ "$("$B/systemctl" show cron.service -p ActiveState --value)" = active ] || fail 'scheduler fixture inactive'
run || fail 'guarded repeat failed with active cron'
# Canonical wrapper text can still target an old launcher with no lock. Its
# exact original argv makes it legacy work; new dispatch must be inert first.
mkfifo "$T/release-older"
/bin/bash -c 'read -r line < "$4"' /usr/local/lib/linux-av/bin/av-root av-power --cron /etc/cron.daily/rkhunter.linux-av-power-original "$T/release-older" & older=$!
ln -s "/proc/$older" "$R/proc/$older"
run & installer=$!
await placeholder
kill -0 "$older" || fail 'older launcher was signaled'
# A still-active inert scheduler repeatedly opens the disabled route while the
# legacy job holds migration in its drain phase. Never execute the final wrapper.
for ((tick=0;tick<10;tick++)); do
    placeholder || fail 'active dispatcher saw an enabled route during drain'
    /bin/sh "$route" || fail 'old-launcher migration did not leave inert dispatch'
    /bin/sleep 0.01
done
printf 'release\n' > "$T/release-older"; wait "$older"; rm "$R/proc/$older"; older=
wait "$installer" || fail 'older-launcher drain failed'
# Interruption after publishing the wrapper but before retiring pending state.
cp -p "$T/package" "$state/pending"
run || fail 'wrapper-with-pending recovery failed'
[ ! -e "$state/pending" ] || fail 'wrapper-with-pending retry not completed'
echo 'ok wait before install; readback before guarded activation; timeout recovery, older launcher and active-cron repeat'
# A real already-open shell script with no affected pathname in argv. Keep fd 0
# open while an inert FIFO read waits; the retained inode, not argv, detects it.
mkfifo "$T/release-open"
printf '#!/bin/sh\nprintf ready > "%s"\nread -r line < "%s"\n' "$T/open-ready" "$T/release-open" > "$route"
chmod 0755 "$route"
/bin/sh < "$route" & opened=$!
ln -s "/proc/$opened" "$R/proc/$opened"
await test -e "$T/open-ready"
# Install has existing code; record its inode to prove no code installation yet.
printf '\n# inert displaced-code sentinel\n' >> "$L/bin/av-power"
old_inode=$(/usr/bin/stat -c %i "$L/bin/av-power")
run & installer=$!
await placeholder
/bin/sh "$route" || fail 'active scheduler could not execute inert placeholder'
[ "$(/usr/bin/stat -c %i "$L/bin/av-power")" = "$old_inode" ] || fail 'installation preceded open-script drain'
kill -0 "$opened" || fail 'open-script fixture was signaled'
printf 'release\n' > "$T/release-open"; wait "$opened"; rm "$R/proc/$opened"; opened=
wait "$installer" || fail 'open-script drain did not recover'
[ "$(/usr/bin/stat -c %i "$L/bin/av-power")" != "$old_inode" ] || fail 'success did not replace displaced code'
cmp "$L/bin/av-power" "$T/release/bin/av-power" || fail 'wrong code after drain'
[ ! -f "$state/pending" ] || fail 'successful open-script migration left pending state'
echo 'ok already-open legacy inode; inert live dispatch during drain; natural exit then successful installation'
# Interrupted-before-replacement retry: raw route plus durable pending remains.
cp -p "$route.linux-av-power-original" "$route"
cp -p "$route" "$state/pending"
run || fail 'pre-replacement interruption retry failed'
grep -qx '# linux-av mains-only cron wrapper' "$route" || fail 'interrupted retry not activated'
# Policy-only refresh uses the same disable/drain/readback/activation protocol.
mkfifo "$T/release-policy"
printf '#!/bin/sh\n# policy-only package replacement\nexit 0\n' > "$route"
/bin/bash -c 'read -r line < "$1"' /etc/cron.daily/rkhunter "$T/release-policy" & policy_job=$!
ln -s "/proc/$policy_job" "$R/proc/$policy_job"
printf '\n# inert policy sentinel\n' >> "$R/etc/systemd/system/linux-av-power.service"
cp "$R/etc/systemd/system/linux-av-power.service" "$T/policy-sentinel"
/bin/bash "$T/policy-driver" > "$T/out" 2>&1 & installer=$!
await placeholder
cmp "$R/etc/systemd/system/linux-av-power.service" "$T/policy-sentinel" || fail 'policy-only write preceded drain'
kill -0 "$policy_job" || fail 'policy-only migration signaled job'
/bin/sh "$route" || fail 'active cron placeholder failed during policy refresh'
printf 'release\n' > "$T/release-policy"; wait "$policy_job"; rm "$R/proc/$policy_job"; policy_job=
wait "$installer" || fail 'policy-only migration failed'
cmp "$R/etc/systemd/system/linux-av-power.service" "$L/systemd/av-power.service" || fail 'policy-only migration failed to replace sentinel'
echo 'ok policy-only refresh disables/drains before policy writes; active cron stays inert then routes guarded'
# Unknown placeholders and unsafe entry types cannot become package originals.
printf '#!/bin/sh\n# linux-av cron migration disabled\nexit 0\n' > "$route"
run && fail 'orphan placeholder accepted'
grep -q 'missing saved original' "$T/out" || fail 'orphan placeholder refusal missing'
rm "$route"; ln -s "$T/package" "$route"
run && fail 'symlink dispatch accepted'
rm "$route"; mkdir "$route"
run && fail 'directory dispatch accepted'
echo 'ok interrupted-before-replacement recovery; orphan placeholder, symlink and directory refusals'
# Every process used by this proof is ours, but proc is intentionally a subset.
# Complete host proc/real uid 0/systemd remain separate gate requirements.
if grep -E '^(start|stop|restart|enable|disable|kill) ' "$R/calls"; then fail 'service action invoked'; fi
printf 'ok fixture-only proof uid=%s host=%s; no host services/chroot/elevation\n' "$EUID" "$(/bin/hostname)"
