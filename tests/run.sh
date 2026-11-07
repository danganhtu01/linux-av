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
    trap 'rm -rf "${WORK:?}"' EXIT
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
TOOLS="mktemp rm sed grep awk cp mv mkdir date cat dirname readlink tail head basename getent cut wc chmod touch tr tee sleep cmp ls"

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
# It removes NAME first: a fixture may hold NAME as a link to the real tool, and writing through
# the link would overwrite that tool (as root, a system binary).
stub() {
    local body; body="$(cat)"
    rm -f -- "${B:?}/$1"
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
        AV_COLOR=never TMPDIR="$D" XDG_STATE_HOME="$H/state" XDG_CONFIG_HOME="$H/config" \
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
# rows: step 1b, --keep-aide-baseline keeps the AIDE database that is already there
# ---------------------------------------------------------------------------
# listing -> every path under the scratch root with its type, size and mtime
listing() { find "$R" -printf '%P %y %s %T@\n' | sort; }

# assert_kept DB-PATH  (after setup: the database was kept, the periodic check is on)
assert_kept() {
    assert_eq "$RC" 0 "enable exit status"
    assert_lacks "$(calls)" "systemd-run" "no baseline unit started"
    assert_lacks "$(calls)" "aideinit" "no aideinit"
    assert_lacks "$(calls)" "aide --init" "no aide --init"
    assert_eq "$(printf '%s\n' "$OUT" | grep -c "WARN .*--keep-aide-baseline: keeping the existing AIDE database $1; not rebuilding")" 1 "one keep warning naming $1"
    assert_lacks "$OUT" "building the AIDE baseline" "no build announced"
    assert_file "$R/etc/systemd/system/aidecheck.timer.d/10-linux-av-bootdelay.conf" "periodic-check drop-in written"
    assert_has "$(calls)" "systemctl enable --now aidecheck.timer" "periodic check enabled"
}

row_keep_aide_baseline_db() {
    new_fixture "$ROW"; printf 'db\n' > "$R/var/lib/aide/aide.db"; cp "$R/var/lib/aide/aide.db" "$D/db0"
    setup enable --keep-aide-baseline
    assert_kept "$R/var/lib/aide/aide.db"
    assert_same "$R/var/lib/aide/aide.db" "$D/db0" "the database is left as it was"
}

row_keep_aide_baseline_db_gz() {
    new_fixture "$ROW" arch; printf 'db\n' > "$R/var/lib/aide/aide.db.gz"; cp "$R/var/lib/aide/aide.db.gz" "$D/db0"
    setup enable --keep-aide-baseline
    assert_kept "$R/var/lib/aide/aide.db.gz"
    assert_same "$R/var/lib/aide/aide.db.gz" "$D/db0" "the database is left as it was"
}

# no database (or only an empty file): refused, and nothing under the root is written
row_keep_aide_baseline_no_db_refused() {
    new_fixture "$ROW"; listing > "$D/before"
    setup enable --keep-aide-baseline
    assert_eq "$RC" 1 "exit status"
    assert_has "$OUT" "$R/var/lib/aide/aide.db or $R/var/lib/aide/aide.db.gz" "names both paths"
    assert_has "$OUT" "run without --keep-aide-baseline to build one" "says what to do"
    assert_eq "$(listing)" "$(cat "$D/before")" "nothing under the root was written"
    assert_eq "$(grep -vc '^id ' "$CALLS")" 0 "nothing but id was called"
}

row_keep_aide_baseline_empty_db_refused() {
    new_fixture "$ROW"; : > "$R/var/lib/aide/aide.db"; : > "$R/var/lib/aide/aide.db.gz"; listing > "$D/before"
    setup enable --keep-aide-baseline
    assert_eq "$RC" 1 "exit status with empty database files"
    assert_has "$OUT" "no AIDE database to keep" "an empty file is not a database"
    assert_eq "$(listing)" "$(cat "$D/before")" "nothing under the root was written"
}

# AV_AIDE_INIT=0 wins over the option, with one warning that says so
row_keep_aide_baseline_aide_init_0() {
    new_fixture "$ROW"; printf 'db\n' > "$R/var/lib/aide/aide.db"
    SETUP_ENV=(AV_AIDE_INIT=0); setup enable --keep-aide-baseline; SETUP_ENV=()
    assert_eq "$RC" 0 "enable exit status"
    assert_lacks "$(calls)" "systemd-run" "no baseline with AV_AIDE_INIT=0"
    assert_lacks "$(calls)" "aideinit" "no aideinit with AV_AIDE_INIT=0"
    assert_has "$OUT" "AV_AIDE_INIT=0 — skipping AIDE baseline build and periodic-check enablement" "the AV_AIDE_INIT=0 skip is announced"
    assert_eq "$(printf '%s\n' "$OUT" | grep -c "WARN .*--keep-aide-baseline is ignored: AV_AIDE_INIT=0 wins")" 1 "one warning says AV_AIDE_INIT=0 wins"
    assert_lacks "$OUT" "keeping the existing" "the database is not reported kept"
    assert_nofile "$R/etc/systemd/system/aidecheck.timer.d" "no timer drop-in with AV_AIDE_INIT=0"
}

row_keep_aide_baseline_aide_init_0_no_db() {
    new_fixture "$ROW"
    SETUP_ENV=(AV_AIDE_INIT=0); setup enable --keep-aide-baseline; SETUP_ENV=()
    assert_eq "$RC" 0 "no database is no error when AV_AIDE_INIT=0 skips AIDE"
    assert_lacks "$OUT" "no AIDE database to keep" "not refused"
    assert_has "$OUT" "--keep-aide-baseline is ignored: AV_AIDE_INIT=0 wins" "the warning"
}

# without the option nothing changes: a database that is there is rebuilt, as before
row_keep_aide_baseline_option_off() {
    new_fixture "$ROW"; printf 'db\n' > "$R/var/lib/aide/aide.db"
    setup enable
    assert_eq "$RC" 0 "enable exit status"
    assert_has "$(calls)" "systemd-run --unit=linux-av-aide-init --property=RuntimeMaxSec=4h --collect aideinit -y -f" "rebuilt without the option"
    assert_lacks "$OUT" "--keep-aide-baseline" "no mention of the option"
}

# any other option to enable or all is refused, before sudo is asked and before any change
row_keep_aide_baseline_unknown_option() {
    new_fixture "$ROW"; listing > "$D/before"
    setup enable --keep-aide-basline
    assert_eq "$RC" 1 "exit status"
    assert_has "$OUT" "unknown option for enable: --keep-aide-basline" "names the option"
    setup enable --keep-aide-baseline --bogus
    assert_eq "$RC" 1 "exit status with a good option and a bad one"
    assert_has "$OUT" "unknown option for enable: --bogus" "names the bad one"
    setup all stray
    assert_eq "$RC" 1 "exit status of all with a stray word"
    assert_has "$OUT" "unknown option for all: stray" "all refuses it too"
    assert_eq "$(listing)" "$(cat "$D/before")" "nothing under the root was written"
    assert_eq "$(grep -vc '^id ' "$CALLS")" 0 "nothing but id was called"
}

row_keep_aide_baseline_sudo() {
    new_fixture "$ROW"
    stub id <<'EOS'
case "${1:-}" in -u) echo 1000 ;; -un) echo tester ;; *) echo "uid=1000(tester)" ;; esac
EOS
    stub sudo </dev/null
    setup enable --bogus
    assert_eq "$RC" 1 "a typo is refused"
    assert_lacks "$(calls)" "sudo" "sudo is not asked for a typo"
    setup enable --keep-aide-baseline
    assert_has "$(calls)" "sudo -E $REPO/bin/av-setup enable --keep-aide-baseline" "the option goes through sudo"
}

# all: the database is looked for before the packages are installed
row_keep_aide_baseline_all_no_db_refused() {
    new_fixture "$ROW"; stub apt-get </dev/null; listing > "$D/before"
    setup all --keep-aide-baseline
    assert_eq "$RC" 1 "exit status"
    assert_has "$OUT" "no AIDE database to keep" "says why"
    assert_lacks "$(calls)" "apt-get" "no package installed"
    assert_eq "$(listing)" "$(cat "$D/before")" "nothing under the root was written"
}

row_keep_aide_baseline_all_db() {
    new_fixture "$ROW"; stub apt-get </dev/null; printf 'db\n' > "$R/var/lib/aide/aide.db"
    setup all --keep-aide-baseline
    assert_kept "$R/var/lib/aide/aide.db"
    assert_has "$(calls)" "apt-get install" "all still installs"
}

row_keep_aide_baseline_documented() {
    new_fixture "$ROW"
    setup --help
    assert_eq "$RC" 0 "--help exit status"
    assert_has "$OUT" "av-setup enable --keep-aide-baseline" "usage names the option on enable"
    assert_has "$OUT" "av-setup all [--keep-aide-baseline]" "usage names the option on all"
    assert_has "$OUT" "AV_AIDE_INIT=0 still wins" "usage says AV_AIDE_INIT=0 wins"
    assert_has "$OUT" "Needs root" "usage ends with its last header line"
    assert_lacks "$OUT" "set -uo pipefail" "usage stops at the header, not at line 18"
    assert_has "$(cat "$REPO/README.md")" "av-setup enable --keep-aide-baseline" "README documents the option"
    assert_has "$(cat "$REPO/MASTER.md")" "av-setup enable --keep-aide-baseline" "MASTER documents the option"
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
# Scan fixtures: neither scanner touches the supplied paths, even for /.
# Arguments are NUL-delimited to preserve spaces, tabs, and newlines.
scan_fixture() {
    new_fixture "$ROW"
    ln -s "$(command -v timeout)" "$B/timeout"
    ln -s "$(command -v realpath)" "$B/realpath"
    MOUNT_NEXT=42; : > "$D/mountinfo"
    printf 'AV_EXCLUDE_DIRS=/legacy\n' > "$H/av.env"
    stub clamscan <<'EOF'
printf '%s\0' "$@" > "$SCAN_ARGS"
exec sleep "${STUB_SCAN_SLEEP:-0}"
EOF
    stub clamdscan <<'EOF'
printf '%s\0' "$@" > "$SCAN_ARGS"
exit 0
EOF
    SCAN_ENV=()
}
scan() {
    OUT="$("$ENV_BIN" -i PATH="$B" HOME="$H" AV_ROOT="$R" AV_CONFIG="$H/av.env" \
        AV_COLOR=never TMPDIR="$D" XDG_STATE_HOME="$H/state" XDG_CONFIG_HOME="$H/config" \
        AV_MOUNTINFO="$D/mountinfo" AV_ENGINE=clamscan SCAN_ARGS="$D/args" \
        CALLS="$CALLS" "${SCAN_ENV[@]}" "$BASH_BIN" "$REPO/bin/av-scan" "$@" --now 2>&1)"
    RC=$?
    ARGS=(); [ ! -f "$D/args" ] || mapfile -d '' -t ARGS < "$D/args"
}
assert_scan_arg() {
    local arg count=0
    for arg in "${ARGS[@]}"; do [ "$arg" != "$1" ] || count=$((count + 1)); done
    assert_eq "$count" 1 "scanner argument $1"
}
assert_mount_count() {
    local arg count=0
    for arg in "${ARGS[@]}"; do
        case "$arg" in --exclude-dir=*) count=$((count + 1)) ;; esac
    done
    # One unchanged AV_EXCLUDE_DIRS argument, plus the mount exclusions.
    assert_eq "$count" "$(($1 + 1))" "mount exclusion count"
    assert_scan_arg '--exclude-dir=^/legacy'
}
mount_entry() {
    local id="${3:-$MOUNT_NEXT}"
    MOUNT_NEXT=$((id + 1))
    printf '%s %s 0:42 / %s rw shared:1 - %s source rw\n' "$id" "${4:-1}" "$1" "$2" >> "$D/mountinfo"
}

row_scan_path_dead_mount() {
    scan_fixture; mount_entry /srv/net cifs
    stub realpath <<'EOF'
exit 99
EOF
    scan --path /srv/net/sub
    assert_eq "$RC" 0 "dead mount is a successful no-op"
    assert_lacks "$(calls)" 'realpath ' "no path lookup on the dead mount"
    assert_lacks "$(calls)" 'clamscan ' "scanner not called"
    assert_has "$OUT" 'not scanning /srv/net/sub:' "lexical path dropped"
}
row_scan_path_missing_symlink() {
    scan_fixture; mount_entry /srv/net cifs
    ln -s /srv/net "$D/alias"
    scan --path "$D/alias/missing/../kept"
    assert_eq "$RC" 0 "missing component through a symlink is a no-op"
    assert_lacks "$(calls)" 'clamscan ' "resolved network path not scanned"
    assert_has "$OUT" 'not scanning /srv/net/kept:' "link resolved with a missing component"
}
row_scan_mount_self_parent() {
    scan_fixture
    printf '42 42 0:42 / / rw - nfs src rw\n' > "$D/mountinfo"
    scan --path /scratch
    assert_eq "$RC" 0 "network root is a successful no-op"
    assert_lacks "$(calls)" 'clamscan ' "network root not scanned"
    assert_has "$OUT" 'not scanning /scratch: it is on a nfs mount at / ' "self-parent root counts"
}
row_scan_mount_hidden_child() {
    scan_fixture
    mount_entry /srv/net cifs 42 1
    mount_entry /srv/net/sub nfs 43 42
    mount_entry /srv/net ext4 44 42
    scan --path /srv/net/sub
    assert_eq "$RC" 0 "local covering mount scanned"
    assert_scan_arg /srv/net/sub
    assert_mount_count 0
    assert_lacks "$OUT" 'not scanning' "hidden child cannot drop a path"
    scan --full
    assert_eq "$RC" 0 "full scan exit"
    assert_mount_count 0
    assert_lacks "$OUT" 'skipping mount' "hidden child cannot add exclusions"
}
row_scan_mount_dropped_parent() {
    scan_fixture
    mount_entry /srv/net/sub nfs 43 42
    mount_entry /srv/net cifs 42 1
    SCAN_ENV=(AV_ENGINE=clamdscan)
    scan --path /srv/net --path /safe
    assert_eq "$RC" 0 "safe path scanned"
    assert_scan_arg /safe
    assert_has "$(calls)" 'clamdscan ' "daemon retained for safe path"
    assert_lacks "$(calls)" 'clamscan ' "no unnecessary switch"
    assert_lacks "$OUT" 'skipping mount' "dropped path adds no exclusions"
    local arg
    for arg in "${ARGS[@]}"; do
        case "$arg" in --exclude-dir=*|--exclude=*) fail "stale mount exclusion: $arg" ;; esac
    done
}
row_scan_mount_ovh_stack() {
    scan_fixture
    mount_entry /srv/onedrive-corsair autofs 42 1
    mount_entry /srv/onedrive-corsair cifs 43 42
    scan --full
    assert_eq "$RC" 0 "full scan exit"
    assert_mount_count 1
    assert_scan_arg '--exclude-dir=^/srv/onedrive-corsair(/|$)'
    assert_scan_arg '--exclude=^/srv/onedrive-corsair(/|$)'
    assert_eq "$(grep -c 'INFO.*skipping mount /srv/onedrive-corsair (type=cifs)' <<< "$OUT")" 1 "visible cifs logged once"
    assert_lacks "$OUT" '(type=autofs)' "covered autofs ignored"
}

row_scan_path_symlink() {
    scan_fixture
    mkdir -p "$D/tree/cloud"; ln -s "$D/tree" "$D/link"
    mount_entry "$D/tree/cloud" cifs
    scan --path "$D/link"
    assert_eq "$RC" 0 "scan exit"
    assert_scan_arg "$D/tree"
    local escaped="${D//./\\.}"
    assert_scan_arg "--exclude-dir=^$escaped/tree/cloud(/|$)"
    assert_mount_count 1
    assert_lacks "$(calls)" "$D/link" "scanner walks the physical path"
}
row_scan_path_relative() {
    scan_fixture; mkdir -p "$D/tree"
    (
        cd "$D" || exit 1
        scan --path ./tree/../tree
        assert_eq "$RC" 0 "scan exit"
        assert_scan_arg "$D/tree"
        [ "$ROW_FAILED" = 0 ]
    ) || fail "relative path row failed"
}
row_scan_path_missing() {
    scan_fixture
    scan --path "$D/missing/../absent"
    assert_eq "$RC" 0 "missing path still passed to scanner"
    assert_scan_arg "$D/absent"
}
row_scan_path_on_mount() {
    scan_fixture; mount_entry /srv/net cifs
    scan --path /srv/net/sub --path /scratch
    assert_eq "$RC" 0 "remaining path scanned"
    assert_scan_arg /scratch
    assert_lacks "$(calls)" '/srv/net/sub' "network path dropped"
    assert_eq "$(grep -c 'WARN.*not scanning /srv/net/sub: it is on a cifs mount at /srv/net (set AV_EXCLUDE_FSTYPES= to scan it)' <<< "$OUT")" 1 "one path warning"
}
row_scan_paths_all_dropped() {
    scan_fixture; mount_entry /srv/net cifs
    scan --path /srv/net --path /srv/net/sub
    assert_eq "$RC" 0 "nothing left is a successful no-op"
    assert_lacks "$(calls)" 'clamscan ' "standalone not run"
    assert_lacks "$(calls)" 'clamdscan ' "daemon not run"
    assert_lacks "$(calls)" 'timeout ' "timeout not run"
    assert_eq "$(grep -c 'WARN.*no scan paths remain after mount exclusions; scan not started' <<< "$OUT")" 1 "one empty-list warning"
    assert_eq "$(grep -c 'WARN.*not scanning' <<< "$OUT")" 2 "one warning per dropped path"
}
row_scan_covered_cifs_ext4() {
    scan_fixture
    mount_entry /srv/stack ext4 43 42
    mount_entry /srv/stack cifs 42 1
    scan --path /srv/stack/sub
    assert_eq "$RC" 0 "local top mount scanned"
    assert_scan_arg /srv/stack/sub
    assert_mount_count 0
    assert_lacks "$OUT" 'skipping mount' "covered cifs ignored"
}
row_scan_covered_ext4_cifs() {
    scan_fixture
    mount_entry /srv/stack ext4 42 1
    mount_entry /srv/stack cifs 43 42
    scan --full
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 1
    assert_scan_arg '--exclude-dir=^/srv/stack(/|$)'
}
row_scan_covered_autofs_ext4() {
    scan_fixture
    mount_entry /srv/stack autofs 42 1
    mount_entry /srv/stack ext4 43 42
    scan --full
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 0
    assert_lacks "$OUT" 'skipping mount' "local disk on autofs scanned"
}
row_scan_covered_autofs_cifs() {
    scan_fixture
    mount_entry /srv/stack autofs 42 1
    mount_entry /srv/stack cifs 43 42
    scan --full
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 1
    assert_eq "$(grep -c 'INFO.*skipping mount /srv/stack (type=cifs)' <<< "$OUT")" 1 "top cifs logged once"
    assert_lacks "$OUT" '(type=autofs)' "covered autofs ignored"
}
row_scan_mount_file() {
    scan_fixture; mount_entry '/srv/a.b' cifs
    scan --full
    assert_eq "$RC" 0 "scan exit"
    assert_scan_arg '--exclude-dir=^/srv/a\.b(/|$)'
    assert_scan_arg '--exclude=^/srv/a\.b(/|$)'
}
row_scan_mount_separator() {
    scan_fixture
    SCAN_ENV=('AV_EXCLUDE_FSTYPES=*')
    printf '42 1 0:42 / /srv/bogus rw cifs source rw\n' > "$D/mountinfo"
    scan --full
    assert_eq "$RC" 0 "malformed line ignored"
    assert_mount_count 0
    assert_lacks "$OUT" 'skipping mount' "no bogus exclusion"
}
row_scan_mount_last_line() {
    scan_fixture
    printf '42 1 0:42 / /srv/last rw - cifs source rw' > "$D/mountinfo"
    scan --full
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 1
    assert_scan_arg '--exclude-dir=^/srv/last(/|$)'
}

row_scan_mount_cifs() {
    scan_fixture; mount_entry /srv/onedrive-corsair cifs
    scan --full
    assert_eq "$RC" 0 "scan exit"
    assert_scan_arg '--exclude-dir=^/srv/onedrive-corsair(/|$)'
    assert_mount_count 1
    assert_eq "$(grep -c 'INFO.*skipping mount /srv/onedrive-corsair (type=cifs)' <<< "$OUT")" 1 "one INFO per mount"
}
row_scan_mount_fstypes() {
    scan_fixture
    local type
    for type in autofs cifs smb3 smbfs nfs nfs4 9p ceph glusterfs afs fuse fuse.sshfs fuse.rclone fuse.gvfsd-fuse; do
        mount_entry "/net/$type" "$type"
    done
    scan --full
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 14
    for type in autofs cifs smb3 smbfs nfs nfs4 9p ceph glusterfs afs fuse fuse.sshfs fuse.rclone fuse.gvfsd-fuse; do
        assert_has "$OUT" "(type=$type)" "skipped $type"
    done
    assert_scan_arg '--exclude-dir=^/net/autofs(/|$)'
    assert_scan_arg '--exclude-dir=^/net/nfs4(/|$)'
    assert_scan_arg '--exclude-dir=^/net/fuse\.sshfs(/|$)'
}
row_scan_mount_local_types() {
    scan_fixture
    local type
    for type in overlay ext4 fuseblk xfs btrfs tmpfs; do mount_entry "/local/$type" "$type"; done
    scan --full
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 0
    assert_lacks "$OUT" 'skipping mount' "local mounts retained"
}
row_scan_mount_escapes() {
    scan_fixture
    mount_entry '/srv/cloud\040files' cifs
    mount_entry '/srv/a.b+c[1](x){y}^$|?*' nfs4
    mount_entry '/srv/tab\011name' autofs
    mount_entry '/srv/new\012line' fuse.sshfs
    mount_entry '/srv/back\134slash\134040' cifs
    scan --full
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 5
    assert_scan_arg '--exclude-dir=^/srv/cloud files(/|$)'
    assert_scan_arg '--exclude-dir=^/srv/a\.b\+c\[1\]\(x\)\{y\}\^\$\|\?\*(/|$)'
    assert_scan_arg $'--exclude-dir=^/srv/tab\tname(/|$)'
    assert_scan_arg $'--exclude-dir=^/srv/new\nline(/|$)'
    assert_scan_arg '--exclude-dir=^/srv/back\\slash\\040(/|$)'
    assert_eq "$(grep -c 'INFO.*skipping mount' <<< "$OUT")" 5 "one log line per encoded mount"
}
row_scan_mount_outside() {
    scan_fixture; mount_entry /srv2/share cifs; mount_entry /other autofs
    scan --path /srv
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 0
    assert_lacks "$OUT" 'skipping mount' "outside mounts not logged"
}
row_scan_mount_switch() {
    scan_fixture; mount_entry /srv/cloud cifs
    SCAN_ENV=(AV_ENGINE=clamdscan)
    scan --path /srv
    assert_eq "$RC" 0 "scan exit"
    assert_has "$OUT" 'INFO' "switch logged"
    assert_has "$OUT" 'mount exclusions require clamscan; switching from clamdscan' "switch reason"
    assert_has "$(calls)" 'clamscan ' "standalone called"
    assert_lacks "$(calls)" 'clamdscan ' "daemon not called"
    assert_scan_arg '--exclude-dir=^/srv/cloud(/|$)'
}
row_scan_mount_daemon_kept() {
    scan_fixture; mount_entry /other/cloud cifs
    SCAN_ENV=(AV_ENGINE=clamdscan)
    scan --path /srv
    assert_eq "$RC" 0 "scan exit"
    assert_has "$(calls)" 'clamdscan ' "daemon retained"
    assert_lacks "$OUT" 'switching' "no switch"
    assert_lacks "$OUT" 'skipping mount' "outside mount ignored"
}
row_scan_mount_disabled() {
    scan_fixture; mount_entry /srv/cloud cifs
    SCAN_ENV=(AV_EXCLUDE_FSTYPES= AV_ENGINE=clamdscan)
    scan --path /srv
    assert_eq "$RC" 0 "scan exit"
    assert_has "$(calls)" 'clamdscan ' "opt-out keeps daemon"
    assert_lacks "$OUT" 'skipping mount' "opt-out"
    SCAN_ENV=(AV_EXCLUDE_FSTYPES=)
    scan --full
    assert_eq "$RC" 0 "standalone exit"
    assert_mount_count 0
}
row_scan_mount_custom_types() {
    scan_fixture; mount_entry /srv/cloud cifs; mount_entry /srv/remote custom.remote
    SCAN_ENV=('AV_EXCLUDE_FSTYPES=custom.*')
    scan --path /srv
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 1
    assert_scan_arg '--exclude-dir=^/srv/remote(/|$)'
}
row_scan_mount_paths() {
    scan_fixture; mount_entry "$PWD/cloud" cifs; mount_entry /srv/exact nfs4
    mount_entry /unselected fuse
    scan --path ./dummy/../ --path /srv/exact/
    assert_eq "$RC" 0 "scan exit"
    assert_mount_count 1
    assert_scan_arg "$PWD"
    assert_lacks "$(calls)" '/srv/exact' "exact network mount path dropped"
    assert_has "$OUT" 'not scanning /srv/exact:' "exact mount warning"
}
row_scan_mount_no_standalone() {
    scan_fixture; mount_entry /srv/cloud cifs; unstub clamscan
    SCAN_ENV=(AV_ENGINE=clamdscan)
    scan --path /srv
    assert_eq "$RC" 0 "existing fallback exit"
    assert_has "$OUT" 'WARN' "warning severity"
    assert_has "$OUT" 'clamdscan cannot enforce mount exclusions' "limitation loud"
}
row_scan_mount_unreadable() {
    scan_fixture; SCAN_ENV=(AV_MOUNTINFO="$D/missing")
    scan --full
    assert_eq "$RC" 2 "cannot safely build exclusions"
    assert_has "$OUT" 'cannot read mount table' "reason"
    assert_lacks "$(calls)" 'clamscan ' "scanner not started"
}
row_scan_mount_reread() {
    scan_fixture
    # The foreground loop calls run_scan repeatedly; exercise that function in
    # one shell so cached mountinfo would fail the second scan.
    sed '/^# Default scan target/,$d' "$REPO/bin/av-scan" > "$D/functions"
    OUT="$("$ENV_BIN" -i PATH="$B" HOME="$H" AV_ROOT="$R" AV_CONFIG="$H/av.env" \
        AV_COLOR=never TMPDIR="$D" XDG_STATE_HOME="$H/state" AV_MOUNTINFO="$D/mountinfo" \
        CALLS="$CALLS" SCAN_ARGS="$D/args" AV_ENGINE=clamscan \
        "$BASH_BIN" -c '
            source <(sed "/^# --- locate/,/^av_detect_distro/d" "$1") --now
            AV_HOME="$2"; source "$2/lib/common.sh"
            run_scan /srv || exit
            printf "42 1 0:42 / /srv/new rw - cifs source rw\n" > "$AV_MOUNTINFO"
            run_scan /srv
        ' sh "$D/functions" "$REPO" 2>&1)"; RC=$?
    ARGS=(); [ ! -f "$D/args" ] || mapfile -d '' -t ARGS < "$D/args"
    assert_eq "$RC" 0 "two scans exit"
    assert_scan_arg '--exclude-dir=^/srv/new(/|$)'
}
row_scan_timeout() {
    scan_fixture; SCAN_ENV=(AV_SCAN_TIMEOUT=2s STUB_SCAN_SLEEP=30)
    local started=$SECONDS
    scan --path /scratch
    assert_eq "$RC" 124 "timeout exit distinct from threats"
    [ "$((SECONDS - started))" -lt 20 ] || fail "scanner was not stopped early (a 30 s scan, a 2 s limit)"
    assert_eq "$(grep -c 'WARN.*stopped at its time limit.*did not finish' <<< "$OUT")" 1 "one unfinished warning"
    assert_lacks "$OUT" 'THREATS FOUND' "timeout is not a finding"
}
row_scan_timeout_disabled() {
    scan_fixture; SCAN_ENV=(AV_SCAN_TIMEOUT=0)
    stub timeout <<'EOF'
exit 99
EOF
    scan --path /scratch
    assert_eq "$RC" 0 "no timeout exit"
    assert_has "$(calls)" 'clamscan ' "scanner ran"
    assert_lacks "$(calls)" 'timeout ' "timeout not invoked"
}
row_scan_timeout_defaults() {
    scan_fixture
    stub timeout <<'EOF'
shift 2
exec "$@"
EOF
    scan --path /scratch
    assert_eq "$RC" 0 "wrapped exit"
    assert_has "$(calls)" 'timeout --kill-after=5m 12h clamscan ' "default timeout and kill grace"
}
row_scan_timeout_killed() {
    scan_fixture
    stub timeout <<'EOF'
exit 137
EOF
    scan --path /scratch
    assert_eq "$RC" 137 "kill exit distinct from threats"
    assert_eq "$(grep -c "WARN.*scan was killed (SIGKILL: its time limit's kill-after, or another killer such as the OOM killer) and did not finish" <<< "$OUT")" 1 "killed unfinished warning"
    assert_lacks "$OUT" 'stopped at its time limit' "SIGKILL cause is uncertain"
}
row_scan_threats() {
    scan_fixture
    stub clamscan <<'EOF'
exit 1
EOF
    scan --path /scratch
    assert_eq "$RC" 1 "finding exit preserved"
    assert_has "$OUT" 'THREATS FOUND' "finding logged"
}

scan_vanished_fixture() {
    scan_fixture
    SCAN_ENV=(AV_SCAN_TIMEOUT=0 OUTPUT="$D/output" SCAN_RC=2)
    stub clamscan <<'STUB'
cat "$OUTPUT"
exit "$SCAN_RC"
STUB
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/gone1" "$D/gone2" > "$D/output"
}
scan_vanished_check() {
    scan --path /scratch
    local files=("$D"/av-scan.*)
    [ ! -e "${files[0]}" ] || fail "temporary scan copy remains"
}
row_scan_vanished_only() {
    scan_vanished_fixture
    printf 'Total errors: 2\n' >> "$D/output"
    scan_vanished_check
    assert_eq "$RC" 0 "vanished exit"
    assert_has "$OUT" 'scan finished; 2 file(s) vanished while it ran (not scanned), no other errors' "warning"
    assert_has "$OUT" "$(cat "$D/output")" "scanner output unchanged and ordered"
}
row_scan_vanished_permission() {
    scan_vanished_fixture
    printf "WARNING: Can't open file %s: Permission denied\nTotal errors: 2\n" "$D/denied" >> "$D/output"
    scan_vanished_check
    assert_eq "$RC" 2 "permission exit"
    assert_has "$OUT" 'scanner error (rc=2)' "error logged"
}
row_scan_vanished_mismatch() {
    scan_vanished_fixture; printf 'Total errors: 3\n' >> "$D/output"; scan_vanished_check
    assert_eq "$RC" 2 "mismatch exit"
}
row_scan_vanished_no_summary() {
    scan_vanished_fixture; scan_vanished_check
    assert_eq "$RC" 2 "missing summary exit"
}
row_scan_vanished_reappeared() {
    scan_vanished_fixture; touch "$D/gone1"; printf 'Total errors: 2\n' >> "$D/output"; scan_vanished_check
    assert_eq "$RC" 2 "reappeared exit"
}
row_scan_vanished_newline() {
    scan_vanished_fixture
    printf "WARNING: Can't open file %s\n%s: No such file or directory\nTotal errors: 1\n" "$D/line" 'break' > "$D/output"
    scan_vanished_check; assert_eq "$RC" 2 "newline exit"
}
row_scan_vanished_threat() {
    scan_vanished_fixture; SCAN_ENV+=(SCAN_RC=1); printf 'Total errors: 2\n' >> "$D/output"; scan_vanished_check
    assert_eq "$RC" 1 "threat exit"; assert_has "$OUT" 'THREATS FOUND' "threat warning"
}
row_scan_vanished_clamdscan() {
    scan_vanished_fixture; printf 'Total errors: 2\n' >> "$D/output"
    stub clamdscan <<'STUB'
cat "$OUTPUT"
exit 2
STUB
    SCAN_ENV+=(AV_ENGINE=clamdscan); scan_vanished_check
    assert_eq "$RC" 2 "daemon error exit"
}
# Read only the installer functions, never its root entrypoint.
root_install_fixture() {
    new_fixture "$ROW"
    sed -n '/^put() {/,/^keep "\$dst\/bin\/av-scan"/{ /^keep "\$dst\/bin\/av-scan"/d; p; }' \
        "$REPO/root-install.sh" > "$D/functions"
}
root_functions() {
    OUT="$("$ENV_BIN" -i PATH="$B" CALLS="$CALLS" "$BASH_BIN" -c '
        die() { echo "$*" >&2; exit 1; }
        source "$1"; shift; "$@"
    ' sh "$D/functions" "$@" 2>&1)"; RC=$?
}
row_root_install_unchanged() {
    root_install_fixture
    printf 'same bytes\n' > "$D/source"; cp "$D/source" "$D/dest"
    local mode
    for mode in 755 644; do
        stub stat <<< "echo '0 0 $mode'"
        root_functions put "$D/source" "0$mode" "$D/dest"
        assert_eq "$RC" 0 "unchanged exit ($mode)"
        assert_has "$OUT" "unchanged: $D/dest" "no rewrite ($mode)"
        assert_nofile "$D/dest.new" "no temporary install ($mode)"
    done
}
row_root_install_backup_failure() {
    root_install_fixture; printf 'original\n' > "$D/dest"
    stub cp <<'EOF'
exit 1
EOF
    root_functions keep "$D/dest"
    assert_eq "$RC" 1 "backup failure is fatal"
    assert_has "$OUT" 'could not keep' "backup failure reason"
    assert_nofile "$D/dest.before-R-3377" "no false backup"
}
row_root_install_backup_optional() {
    root_install_fixture
    stub cp <<'EOF'
exit 1
EOF
    root_functions keep "$D/absent"
    assert_eq "$RC" 0 "missing file needs no backup"
    printf 'new\n' > "$D/dest"; printf 'old\n' > "$D/dest.before-R-3377"
    root_functions keep "$D/dest"
    assert_eq "$RC" 0 "existing backup kept"
    assert_eq "$(cat "$D/dest.before-R-3377")" old "first backup unchanged"
    assert_lacks "$(calls)" 'cp ' "no copy attempted"
}
row_root_install_backup_saved() {
    root_install_fixture; printf 'original\n' > "$D/dest"
    root_functions keep "$D/dest"
    assert_eq "$RC" 0 "backup exit"
    assert_same "$D/dest" "$D/dest.before-R-3377" "backup contents"
}
row_root_install_perl_guard() {
    new_fixture "$ROW"
    sed -n '/^# The single quotes/,/^put "\$t\/linux-av.conf"/p' \
        "$REPO/root-install.sh" > "$D/config-fragment"
    local status
    for status in 1 0; do
        stub perl <<< "exit $status"
        OUT="$("$ENV_BIN" -i PATH="$B" CALLS="$CALLS" "$BASH_BIN" -c '
            die() { echo "$*" >&2; exit 1; }
            put() { cp "$1" "$t/installed"; }
            t="$1"; source "$t/config-fragment"
        ' sh "$D" 2>&1)"; RC=$?
        assert_eq "$RC" "$status" "Perl status $status"
        if [ "$status" = 1 ]; then
            assert_nofile "$D/installed" "invalid Perl never installed"
            assert_has "$OUT" 'does not parse' "parse refusal reason"
        else
            assert_same "$D/linux-av.conf" "$D/installed" "valid Perl installed"
        fi
    done
    assert_has "$(calls)" "perl -c $D/linux-av.conf" "checks the temporary file"
}
row_root_install_library_first() {
    new_fixture "$ROW"
    # Run just the two put calls with a recording function, without installing anything.
    sed -n '/^put "\$here\/.*" .*"\$dst\//p' "$REPO/root-install.sh" > "$D/puts"
    OUT="$("$BASH_BIN" -c '
        here=tree; dst=dest
        put() { echo "$1"; }
        source "$1"
    ' sh "$D/puts")"
    assert_eq "$OUT" $'tree/lib/common.sh\ntree/bin/av-scan' "library installed before its consumer"
}

# The runner refuses root-install.sh unless each "# sha256 <hex> <relpath>" line names its file's
# current SHA-256; a stale line would only show up on his card. Check them here.
row_root_install_hashes() {
    new_fixture "$ROW"
    local hash sum hex rel n=0
    while read -r hash sum hex rel; do
        [ "$hash $sum" = '# sha256' ] || continue
        n=$((n+1))
        assert_eq "$(sha256sum < "$REPO/$rel" | cut -c1-64)" "$hex" "root-install.sh lists the SHA-256 of $rel"
    done < "$REPO/root-install.sh"
    assert_eq "$n" 2 "root-install.sh lists two files"
}

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
