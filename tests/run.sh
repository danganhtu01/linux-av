#!/usr/bin/env bash
# tests/run.sh — linux-av's test suite (bash, no dependencies, no root).
#
#   tests/run.sh               run every row
#   tests/run.sh ROW [ROW...]  run the named rows only (see `grep '^row_' tests/run.sh`)
#
# Each row builds a scratch root (AV_ROOT) holding copies of the /etc and /var files
# the code edits, and a PATH that holds only symlinks to the plain tools plus stubs
# for systemctl, systemd-run, rkhunter, aideinit, aide, id (and mail/sendmail in the
# rows that want a mailer). Nothing outside the scratch directory is read or written.
#
# Environment:
#   AV_REPO_UNDER_TEST  the checkout to test (default: the one this file is in);
#                       tests/mutants.sh points it at a mutated copy
#   AV_TEST_KEEP=1      keep the scratch directory (default: removed on exit)
#   TMPDIR              where the scratch directory is made
# Exit status: 0 when every selected row passed, 1 otherwise.

set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${AV_REPO_UNDER_TEST:-$(cd -P "$HERE/.." && pwd)}"
BASH_BIN="$(command -v bash)"
ENV_BIN="$(command -v env)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/linux-av-test.XXXXXX")" || exit 2
if [ "${AV_TEST_KEEP:-0}" != 1 ]; then
    trap 'rm -rf "$WORK"' EXIT
else
    echo "scratch kept: $WORK"
fi

PASS=0; FAIL=0; ROW=""; ROW_FAILED=0

fail() { printf '  FAIL %s: %s\n' "$ROW" "$*"; ROW_FAILED=1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; }
assert_has() { # text needle label
    case "$1" in *"$2"*) : ;; *) fail "$3: output lacks [$2]" ;; esac
}
assert_lacks() {
    case "$1" in *"$2"*) fail "$3: output has [$2]" ;; *) : ;; esac
}
assert_file() { [ -f "$1" ] || fail "$2: $1 does not exist"; }
assert_nofile() { [ ! -e "$1" ] || fail "$2: $1 exists"; }
assert_same() { cmp -s "$1" "$2" || fail "$3: $1 and $2 differ"; }

# ---------------------------------------------------------------------------
# fixture
# ---------------------------------------------------------------------------
TOOLS="sed grep awk cp mv mkdir date cat dirname readlink tail head basename getent cut wc chmod touch tr tee sleep cmp ls"

# new_fixture NAME [debian|arch]  -> sets R (AV_ROOT), B (PATH dir), H (HOME), CALLS
new_fixture() {
    local name="$1" family="${2:-debian}" t p
    D="$WORK/$name"; R="$D/root"; B="$D/bin"; H="$D/home"; CALLS="$D/calls"
    mkdir -p "$R/etc/chkrootkit" "$R/etc/default" "$R/etc/systemd/system" \
             "$R/var/log/chkrootkit" "$R/var/log/aide" "$R/var/lib/aide" \
             "$R/var/lib/rkhunter/db" "$B" "$H"
    : > "$CALLS"; : > "$H/av.env"
    for t in $TOOLS; do
        p="$(command -v "$t")" && ln -sf "$p" "$B/$t"
    done
    if [ "$family" = debian ]; then
        printf 'ID=debian\n' > "$R/etc/os-release"
    else
        printf 'ID=arch\n' > "$R/etc/os-release"
    fi
    # /etc files as Debian trixie ships them (the lines the code edits)
    cat > "$R/etc/chkrootkit/chkrootkit.conf" <<'EOF'
RUN_DAILY="true"
DIFF_MODE="true"
## Email address to which output is sent.
MAILTO="root"
EOF
    cat > "$R/etc/default/aide" <<'EOF'
CONFIG="/etc/aide/aide.conf"
#CRON_DAILY_RUN=yes
#MAILTO=root
#MAILWIDTH=990
COMMAND=update
EOF
    cat > "$R/etc/default/rkhunter" <<'EOF'
CRON_DAILY_RUN=""
CRON_DB_UPDATE=""
DB_UPDATE_EMAIL="false"
REPORT_EMAIL="root"
APT_AUTOGEN="false"
EOF
    stub id <<'EOF'
case "${1:-}" in -u) echo 0 ;; -un) echo root ;; *) echo "uid=0(root)" ;; esac
EOF
    stub systemctl <<'EOF'
case "${1:-}" in
    is-active)
        u=""; for a in "$@"; do case "$a" in *.service) u="$a" ;; esac; done
        case "$u" in *aide*) 
            case " ${STUB_ACTIVE:-} " in *" $u "*) exit 0 ;; *) exit 1 ;; esac
        esac
        exit 0 ;;
    cat) case " ${STUB_NOCAT:-} " in *" ${2:-} "*) exit 1 ;; esac; exit 0 ;;
esac
exit 0
EOF
    stub systemd-run </dev/null
    stub rkhunter </dev/null
    stub aideinit </dev/null
    stub aide </dev/null
}

# stub NAME  (body on stdin; a stub always records "NAME args" in $CALLS first)
stub() {
    local body; body="$(cat)"
    # shellcheck disable=SC2016
    { printf '#!%s\n' "$BASH_BIN"
      printf 'echo "%s $*" >> "$CALLS"\n' "$1"
      printf '%s\n' "$body"
    } > "$B/$1"
    chmod +x "$B/$1"
}
unstub() { rm -f "$B/$1"; }

# setup ARGS...  -> runs bin/av-setup with the fixture; sets OUT and RC.
# Extra environment goes in SETUP_ENV (an array of NAME=value).
SETUP_ENV=()
setup() {
    OUT="$("$ENV_BIN" -i PATH="$B" HOME="$H" AV_ROOT="$R" AV_CONFIG="$H/av.env" \
        AV_COLOR=never XDG_STATE_HOME="$H/state" XDG_CONFIG_HOME="$H/config" \
        CALLS="$CALLS" "${SETUP_ENV[@]}" "$BASH_BIN" "$REPO/bin/av-setup" "$@" 2>&1)"
    RC=$?
}
calls() { cat "$CALLS"; }
conf() { printf '%s' "$R/etc/$1"; }

# ---------------------------------------------------------------------------
# rows: step 2, reports never go to a mailer that is not there
# ---------------------------------------------------------------------------
row_mail_edits_applied() {
    new_fixture "$ROW"; cp "$R/etc/chkrootkit/chkrootkit.conf" "$D/chk.orig"
    cp "$R/etc/default/aide" "$D/aide.orig"; cp "$R/etc/default/rkhunter" "$D/rk.orig"
    setup enable
    assert_eq "$RC" 0 "enable exit status"
    assert_has "$(cat "$(conf chkrootkit/chkrootkit.conf)")" 'MAILTO=""' "chkrootkit MAILTO"
    assert_lacks "$(cat "$(conf chkrootkit/chkrootkit.conf)")" 'MAILTO="root"' "chkrootkit old MAILTO"
    assert_has "$(cat "$(conf default/aide)")" 'MAILCMD=":"' "aide MAILCMD"
    assert_has "$(cat "$(conf default/rkhunter)")" 'REPORT_EMAIL=""' "rkhunter REPORT_EMAIL"
    assert_same "$(conf chkrootkit/chkrootkit.conf).linux-av.bak" "$D/chk.orig" "chkrootkit .bak"
    assert_same "$(conf default/aide).linux-av.bak" "$D/aide.orig" "aide .bak"
    assert_same "$(conf default/rkhunter).linux-av.bak" "$D/rk.orig" "rkhunter .bak"
    assert_has "$OUT" "MAILTO=\"\"" "log names the change"
}

row_mail_edit_idempotent() {
    new_fixture "$ROW"
    setup enable
    cp "$(conf chkrootkit/chkrootkit.conf)" "$D/c1"; cp "$(conf default/aide)" "$D/a1"
    cp "$(conf default/rkhunter)" "$D/r1"
    setup enable
    assert_same "$(conf chkrootkit/chkrootkit.conf)" "$D/c1" "chkrootkit conf after 2nd run"
    assert_same "$(conf default/aide)" "$D/a1" "aide conf after 2nd run"
    assert_same "$(conf default/rkhunter)" "$D/r1" "rkhunter conf after 2nd run"
    assert_lacks "$OUT" "set MAILTO" "2nd run rewrites nothing (chkrootkit)"
    assert_lacks "$OUT" "added MAILCMD" "2nd run rewrites nothing (aide)"
    assert_lacks "$OUT" "set REPORT_EMAIL" "2nd run rewrites nothing (rkhunter)"
    assert_lacks "$OUT" "set CRON_DAILY_RUN" "2nd run rewrites nothing (rkhunter cron)"
}

row_mail_bak_first_only() {
    new_fixture "$ROW"; cp "$R/etc/chkrootkit/chkrootkit.conf" "$D/chk.orig"
    setup enable
    sed -i 's|^MAILTO=.*|MAILTO="someone"|' "$(conf chkrootkit/chkrootkit.conf)"
    setup enable
    assert_same "$(conf chkrootkit/chkrootkit.conf).linux-av.bak" "$D/chk.orig" ".bak is still the first original"
    assert_has "$(cat "$(conf chkrootkit/chkrootkit.conf)")" 'MAILTO=""' "second edit applied"
}

row_mail_untouched_with_mail() {
    new_fixture "$ROW"; stub mail </dev/null
    cp "$R/etc/chkrootkit/chkrootkit.conf" "$D/c0"; cp "$R/etc/default/aide" "$D/a0"
    setup enable
    assert_same "$(conf chkrootkit/chkrootkit.conf)" "$D/c0" "chkrootkit conf with mail on PATH"
    assert_same "$(conf default/aide)" "$D/a0" "aide conf with mail on PATH"
    assert_has "$(cat "$(conf default/rkhunter)")" 'REPORT_EMAIL="root"' "rkhunter REPORT_EMAIL with mail on PATH"
    assert_nofile "$(conf chkrootkit/chkrootkit.conf).linux-av.bak" "no .bak with a mailer"
}

row_mail_untouched_with_sendmail() {
    new_fixture "$ROW"; stub sendmail </dev/null
    cp "$R/etc/chkrootkit/chkrootkit.conf" "$D/c0"
    setup enable
    assert_same "$(conf chkrootkit/chkrootkit.conf)" "$D/c0" "chkrootkit conf with sendmail on PATH"
    assert_has "$(cat "$(conf default/rkhunter)")" 'REPORT_EMAIL="root"' "rkhunter REPORT_EMAIL with sendmail on PATH"
}

row_aide_custom_mailcmd_kept() {
    new_fixture "$ROW"
    printf 'MAILCMD="/usr/local/bin/notify"\n' >> "$R/etc/default/aide"
    setup enable
    assert_has "$(cat "$(conf default/aide)")" 'MAILCMD="/usr/local/bin/notify"' "own MAILCMD kept"
    assert_lacks "$(cat "$(conf default/aide)")" 'MAILCMD=":"' "no overwrite"
    assert_has "$OUT" "already sets MAILCMD" "log says why"
}

row_mail_optout() {
    new_fixture "$ROW"; cp "$R/etc/chkrootkit/chkrootkit.conf" "$D/c0"; cp "$R/etc/default/aide" "$D/a0"
    SETUP_ENV=(AV_QUIET_REPORTS=0); setup enable; SETUP_ENV=()
    assert_same "$(conf chkrootkit/chkrootkit.conf)" "$D/c0" "chkrootkit conf with AV_QUIET_REPORTS=0"
    assert_same "$(conf default/aide)" "$D/a0" "aide conf with AV_QUIET_REPORTS=0"
    assert_has "$(cat "$(conf default/rkhunter)")" 'REPORT_EMAIL="root"' "rkhunter REPORT_EMAIL with AV_QUIET_REPORTS=0"
}

row_mail_append_when_absent() {
    new_fixture "$ROW"
    printf 'RUN_DAILY="true"' > "$R/etc/chkrootkit/chkrootkit.conf"   # no MAILTO, no trailing newline
    setup enable
    assert_eq "$(tail -n 1 "$(conf chkrootkit/chkrootkit.conf)")" 'MAILTO=""' "MAILTO appended on its own line"
    assert_eq "$(head -n 1 "$(conf chkrootkit/chkrootkit.conf)")" 'RUN_DAILY="true"' "first line intact"
}

# ---------------------------------------------------------------------------
# rows: step 1, the AIDE baseline in its own unit
# ---------------------------------------------------------------------------
row_baseline_detached_debian() {
    new_fixture "$ROW"
    setup enable
    assert_eq "$RC" 0 "enable exit status"
    assert_has "$(calls)" "systemd-run --unit=linux-av-aide-init --property=RuntimeMaxSec=4h --collect aideinit -y -f" "systemd-run command line"
    assert_lacks "$(calls)" "
aideinit" "aideinit not run directly"
    assert_has "$OUT" "systemctl status linux-av-aide-init" "how to watch (status)"
    assert_has "$OUT" "journalctl -u linux-av-aide-init" "how to watch (journal)"
    assert_has "$OUT" '"no database"' "periodic check reports no database until done"
}

row_baseline_detached_arch() {
    new_fixture "$ROW" arch
    setup enable
    assert_eq "$RC" 0 "enable exit status"
    assert_has "$(calls)" "systemd-run --unit=linux-av-aide-init --property=RuntimeMaxSec=4h --collect sh -c aide --init && mv -f \"\$1\" \"\$2\" sh $R/var/lib/aide/aide.db.new.gz $R/var/lib/aide/aide.db.gz" "arch command line"
    assert_lacks "$(calls)" "aideinit" "no aideinit on arch"
    assert_has "$(cat "$(conf default/rkhunter)")" 'CRON_DAILY_RUN=""' "arch: rkhunter cron setting not touched"
}

row_baseline_running_not_twice() {
    new_fixture "$ROW"
    SETUP_ENV=(STUB_ACTIVE=linux-av-aide-init.service); setup enable; SETUP_ENV=()
    assert_lacks "$(calls)" "systemd-run" "no second start"
    assert_has "$OUT" "already building" "says so"
}

row_baseline_timeout_env() {
    new_fixture "$ROW"
    SETUP_ENV=(AV_AIDE_INIT_TIMEOUT=90min AV_AIDE_INIT_UNIT=my-aide); setup enable; SETUP_ENV=()
    assert_has "$(calls)" "systemd-run --unit=my-aide --property=RuntimeMaxSec=90min --collect aideinit -y -f" "unit and limit from env"
}

row_baseline_skip_aide_init_0() {
    new_fixture "$ROW"
    SETUP_ENV=(AV_AIDE_INIT=0); setup enable; SETUP_ENV=()
    assert_lacks "$(calls)" "systemd-run" "no baseline with AV_AIDE_INIT=0"
    assert_lacks "$(calls)" "aideinit" "no aideinit with AV_AIDE_INIT=0"
    assert_has "$OUT" "AV_AIDE_INIT=0" "skip is announced"
    assert_nofile "$R/etc/systemd/system/aidecheck.timer.d" "no timer drop-in with AV_AIDE_INIT=0"
}

row_baseline_foreground_without_systemd_run() {
    new_fixture "$ROW"; unstub systemd-run
    setup enable
    assert_has "$(calls)" "aideinit -y -f" "aideinit runs in the foreground"
    assert_has "$OUT" "systemd-run not found" "warns"
}

row_baseline_timer_dropin_in_root() {
    new_fixture "$ROW"
    setup enable
    assert_file "$R/etc/systemd/system/aidecheck.timer.d/10-linux-av-bootdelay.conf" "drop-in under AV_ROOT"
}

# ---------------------------------------------------------------------------
# rows: step 3, rkhunter nightly
# ---------------------------------------------------------------------------
row_rkhunter_daily_on() {
    new_fixture "$ROW"; cp "$R/etc/default/rkhunter" "$D/rk.orig"
    setup enable
    assert_has "$(cat "$(conf default/rkhunter)")" 'CRON_DAILY_RUN="true"' "CRON_DAILY_RUN"
    assert_has "$(cat "$(conf default/rkhunter)")" 'CRON_DB_UPDATE="true"' "CRON_DB_UPDATE"
    assert_same "$(conf default/rkhunter).linux-av.bak" "$D/rk.orig" "rkhunter .bak"
}

row_rkhunter_propupd_when_no_database() {
    new_fixture "$ROW"
    setup enable
    assert_has "$(calls)" "rkhunter --propupd" "propupd runs with no rkhunter.dat"
}

row_rkhunter_propupd_skipped_with_database() {
    new_fixture "$ROW"; : > "$R/var/lib/rkhunter/db/rkhunter.dat"
    setup enable
    assert_lacks "$(calls)" "rkhunter --propupd" "propupd skipped when rkhunter.dat exists"
}

row_rkhunter_optout() {
    new_fixture "$ROW"
    SETUP_ENV=(AV_RKHUNTER_DAILY=0); setup enable; SETUP_ENV=()
    assert_has "$(cat "$(conf default/rkhunter)")" 'CRON_DAILY_RUN=""' "CRON_DAILY_RUN untouched"
    assert_has "$(cat "$(conf default/rkhunter)")" 'CRON_DB_UPDATE=""' "CRON_DB_UPDATE untouched"
    assert_lacks "$(calls)" "rkhunter --propupd" "no propupd with AV_RKHUNTER_DAILY=0"
}

row_rkhunter_warns_without_cron() {
    new_fixture "$ROW"
    SETUP_ENV=("STUB_NOCAT=cron.service crond.service"); setup enable; SETUP_ENV=()
    assert_has "$OUT" "no cron service found" "warns that /etc/cron.daily will not run"
    new_fixture "${ROW}-with"
    setup enable
    assert_lacks "$OUT" "no cron service found" "silent when cron.service exists"
    new_fixture "${ROW}-crond-only-missing"
    SETUP_ENV=("STUB_NOCAT=crond.service"); setup enable; SETUP_ENV=()
    assert_lacks "$OUT" "no cron service found" "silent when cron.service exists and crond.service does not"
}

# ---------------------------------------------------------------------------
# rows: step 4, chkrootkit baseline
# ---------------------------------------------------------------------------
clean_today() {
    printf 'Checking `amd'"'"'... not found\nChecking `bindshell'"'"'... not infected\n' > "$R/var/log/chkrootkit/log.today"
}

row_chkrootkit_baseline_adopted() {
    new_fixture "$ROW"; clean_today
    setup enable
    assert_file "$R/var/log/chkrootkit/log.expected" "log.expected created"
    assert_same "$R/var/log/chkrootkit/log.today" "$R/var/log/chkrootkit/log.expected" "copy of log.today"
}

row_chkrootkit_baseline_infected() {
    new_fixture "$ROW"; clean_today
    printf 'Checking `bindshell'"'"'... INFECTED (PORTS:  465)\n' >> "$R/var/log/chkrootkit/log.today"
    setup enable
    assert_nofile "$R/var/log/chkrootkit/log.expected" "INFECTED is not adopted"
    setup chkrootkit-baseline
    assert_eq "$RC" 1 "subcommand exit status on a finding"
}

row_chkrootkit_baseline_vulnerable() {
    new_fixture "$ROW"; clean_today
    printf 'Checking `lpd'"'"'... Vulnerable\n' >> "$R/var/log/chkrootkit/log.today"
    setup enable
    assert_nofile "$R/var/log/chkrootkit/log.expected" "Vulnerable is not adopted"
}

row_chkrootkit_baseline_keeps_existing() {
    new_fixture "$ROW"; clean_today
    printf 'my own expected output\n' > "$R/var/log/chkrootkit/log.expected"
    setup enable
    assert_eq "$(cat "$R/var/log/chkrootkit/log.expected")" "my own expected output" "log.expected not overwritten"
}

row_chkrootkit_baseline_needs_a_run() {
    new_fixture "$ROW"
    setup enable
    assert_nofile "$R/var/log/chkrootkit/log.expected" "no log.today, no baseline"
    : > "$R/var/log/chkrootkit/log.today"
    setup enable
    assert_nofile "$R/var/log/chkrootkit/log.expected" "empty log.today, no baseline"
    assert_has "$OUT" "av-setup chkrootkit-baseline" "tells him the one command"
}

row_chkrootkit_baseline_command() {
    new_fixture "$ROW"; clean_today
    setup chkrootkit-baseline
    assert_eq "$RC" 0 "subcommand exit status on a clean run"
    assert_file "$R/var/log/chkrootkit/log.expected" "subcommand adopts the clean run"
}

# ---------------------------------------------------------------------------
# rows: step 5, status
# ---------------------------------------------------------------------------
row_status_baseline_absent() {
    new_fixture "$ROW"
    setup status
    assert_has "$OUT" "aide baseline:       absent" "no database"
}

row_status_baseline_present() {
    new_fixture "$ROW"; printf 'db\n' > "$R/var/lib/aide/aide.db"
    setup status
    assert_has "$OUT" "aide baseline:       present" "database present"
}

row_status_baseline_building() {
    new_fixture "$ROW"
    SETUP_ENV=(STUB_ACTIVE=linux-av-aide-init.service); setup status; SETUP_ENV=()
    assert_has "$OUT" "aide baseline:       building" "unit active"
}

row_status_reports_quiet() {
    new_fixture "$ROW"
    setup enable
    setup status
    assert_has "$OUT" "aide report:         $R/var/log/aide/ (mail off)" "aide report line"
    assert_has "$OUT" "chkrootkit report:   journal (chkrootkit.service) and $R/var/log/chkrootkit/log.today (mail off)" "chkrootkit report line"
    assert_has "$OUT" "rkhunter report:     $R/var/log/rkhunter.log (mail off)" "rkhunter report line"
    assert_has "$OUT" "rkhunter daily run:  on" "rkhunter on after enable"
}

row_status_reports_mail_kept() {
    new_fixture "$ROW"; stub mail </dev/null
    setup enable
    setup status
    assert_has "$OUT" 'chkrootkit report:' "line exists"
    assert_has "$OUT" "chkrootkit report:   $R/var/log/chkrootkit/log.today (mail to \"root\")" "mail kept is shown"
    assert_has "$OUT" "rkhunter daily run:  on" "rkhunter on (mail does not matter)"
}

row_status_rkhunter_off() {
    new_fixture "$ROW"
    setup status
    assert_has "$OUT" "rkhunter daily run:  off" "off in the Debian default"
    assert_has "$OUT" "rkhunter database:   absent" "no rkhunter.dat"
    : > "$R/var/lib/rkhunter/db/rkhunter.dat"
    setup status
    assert_has "$OUT" "rkhunter database:   present" "rkhunter.dat present"
}

row_status_chkrootkit_baseline() {
    new_fixture "$ROW"
    setup status
    assert_has "$OUT" "chkrootkit baseline: absent" "absent"
    : > "$R/var/log/chkrootkit/log.expected"
    setup status
    assert_has "$OUT" "chkrootkit baseline: present" "present"
}

row_chkrootkit_baseline_warning() {
    new_fixture "$ROW"; clean_today
    printf 'Searching for Showtee rootkit... WARNING\n\nWARNING: Possible Showtee rootkit installed:\n/usr/lib/.egcs\n' >> "$R/var/log/chkrootkit/log.today"
    setup enable
    assert_nofile "$R/var/log/chkrootkit/log.expected" "a WARNING finding is not adopted"
    assert_has "$OUT" "cp -a $R/var/log/chkrootkit/log.today $R/var/log/chkrootkit/log.expected" "gives the command for after reading"
}

row_mail_symlink_left_alone() {
    new_fixture "$ROW"; mkdir -p "$D/managed"
    mv "$R/etc/default/rkhunter" "$D/managed/rkhunter"; cp "$D/managed/rkhunter" "$D/rk.orig"
    ln -s "$D/managed/rkhunter" "$R/etc/default/rkhunter"
    setup enable
    [ -L "$R/etc/default/rkhunter" ] || fail "symlink replaced by a regular file"
    assert_same "$D/managed/rkhunter" "$D/rk.orig" "symlink target untouched"
    assert_has "$OUT" "is a symlink" "says why"
}

row_mail_bak_failure_left_alone() {
    new_fixture "$ROW"; cp "$R/etc/chkrootkit/chkrootkit.conf" "$D/c0"
    ln -s "$D/nowhere/bak" "$R/etc/chkrootkit/chkrootkit.conf.linux-av.bak"   # dangling: cp will not write through it
    setup enable
    assert_same "$R/etc/chkrootkit/chkrootkit.conf" "$D/c0" "no edit without a backup"
    assert_nofile "$D/nowhere/bak" "nothing written through the symlink"
    assert_has "$OUT" "could not keep" "says why"
}

row_mail_multiline_value_left_alone() {
    new_fixture "$ROW"
    printf 'RUN_DAILY="true"\nMAILTO="root,\\\nadmin"\n' > "$R/etc/chkrootkit/chkrootkit.conf"
    cp "$R/etc/chkrootkit/chkrootkit.conf" "$D/c0"
    setup enable
    assert_same "$R/etc/chkrootkit/chkrootkit.conf" "$D/c0" "file left as it was"
    assert_nofile "$R/etc/chkrootkit/chkrootkit.conf.linux-av.bak" "no backup for an edit not made"
    assert_has "$OUT" "would not parse" "says why"
}

row_mail_absent_file_not_created() {
    new_fixture "$ROW"; mv "$R/etc/default/aide" "$D/aide.away"
    setup enable
    assert_nofile "$R/etc/default/aide" "an absent /etc/default/aide is not created"
    assert_has "$OUT" "/etc/default/aide is not present" "says why"
}

row_av_root_refused_as_root() {
    new_fixture "$ROW"
    OUT="$("$ENV_BIN" -i PATH="$B" HOME="$H" AV_ROOT="$R" AV_CONFIG="$H/av.env" AV_COLOR=never \
        XDG_STATE_HOME="$H/state" "$BASH_BIN" -c '. "$1/lib/common.sh"; av_refuse_root_prefix 0; echo reached' \
        sh "$REPO" 2>&1)"; RC=$?
    assert_eq "$RC" 1 "exit status with AV_ROOT as root"
    assert_has "$OUT" "AV_ROOT=$R is for tests only" "says why"
    assert_lacks "$OUT" "reached" "stops there"
    assert_eq "$(grep -c '^av_refuse_root_prefix "${EUID:-$(id -u)}"$' "$REPO/lib/common.sh")" 1 "called when common.sh is sourced"
}

# ---------------------------------------------------------------------------
ROWS="$(declare -F | awk '$3 ~ /^row_/ {print $3}' | sort)"
if [ "$#" -gt 0 ]; then
    for want in "$@"; do
        case "$ROWS" in *"row_$want"*) : ;; *) echo "no such row: $want"; exit 2 ;; esac
    done
    SELECT="$*"
else
    SELECT=""
fi
for fn in $ROWS; do
    ROW="${fn#row_}"
    if [ -n "$SELECT" ]; then
        case " $SELECT " in *" $ROW "*) : ;; *) continue ;; esac
    fi
    ROW_FAILED=0
    "$fn"
    if [ "$ROW_FAILED" -eq 0 ]; then
        PASS=$((PASS + 1)); printf 'ok   %s\n' "$ROW"
    else
        FAIL=$((FAIL + 1))
    fi
done
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
