#!/usr/bin/env bash
# exempt: GNU-ONLY GNU/Linux hosts only (Debian, Ubuntu and Arch, the distros linux-av supports): sed -i, find -printf, stat -c
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
TIMEOUT_BIN="$(command -v timeout)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/linux-av-test.XXXXXX")" || exit 2
if [ "${AV_TEST_KEEP:-0}" != 1 ]; then
    trap 'rm -rf "${WORK:?}"' EXIT
else
    echo "scratch kept: $WORK"
fi

PASS=0; FAIL=0; ROW=""; ROW_FAILED=0; D=""

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
TOOLS="mktemp rm sed grep awk cp mv mkdir date cat dirname readlink tail head basename getent cut wc chmod touch tr tee cmp ls stat"

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
# OC-T-0047 round 2: strict output whitelist and private-copy isolation regressions.
scan_fixture() {
    new_fixture "$ROW"
    ln -s "$(command -v timeout)" "$B/timeout"
    ln -s "$(command -v realpath)" "$B/realpath"
    MOUNT_NEXT=42; : > "$D/mountinfo"
    printf 'AV_EXCLUDE_DIRS=/legacy\nAV_EXCLUDE_PATTERNS=""\nAV_FULL_EVERY=0\n' > "$H/av.env"
    stub clamscan <<'EOF'
printf '%s\0' "$@" > "$SCAN_ARGS"
if [ "${STUB_SCAN_LOOP:-0}" = 1 ]; then
    while :; do :; done
fi
exit 0
EOF
    stub clamdscan <<'EOF'
printf '%s\0' "$@" > "$SCAN_ARGS"
exit 0
EOF
    mkdir -p "$B/plain"
    ln -s "$(command -v tee)" "$B/plain/tee"
    stub tee <<'EOF'
printf '%s\n' "$1" >> "${SCAN_ARGS%/*}/copies"
stat -c '%a' "${1%/*}" >> "${SCAN_ARGS%/*}/copy-modes"
exec "${BASH_SOURCE[0]%/*}/plain/tee" "$@"
EOF
    SCAN_ENV=()
}
scan() {
    rm -f -- "$D/args"
    : > "$D/copies"; : > "$D/copy-modes"
    OUT="$("$TIMEOUT_BIN" 3s "$ENV_BIN" -i PATH="$B" HOME="$H" AV_ROOT="$R" AV_CONFIG="$H/av.env" \
        AV_COLOR=never TMPDIR="$D" XDG_STATE_HOME="$H/state" XDG_CONFIG_HOME="$H/config" \
        AV_MOUNTINFO="$D/mountinfo" AV_ENGINE=clamscan SCAN_ARGS="$D/args" \
        CALLS="$CALLS" "${SCAN_ENV[@]}" "$BASH_BIN" "$REPO/bin/av-scan" "$@" --now 2>&1)"
    RC=$?
    ARGS=(); [ ! -f "$D/args" ] || mapfile -d '' -t ARGS < "$D/args"
    assert_copy_isolation
}
assert_copy_isolation() {
    local copy dir escaped char i mode arg invocations=0
    for arg in "${ARGS[@]}"; do [ "$arg" != --stdout ] || invocations=$((invocations + 1)); done
    [ "$invocations" -gt 0 ] || invocations=1
    while IFS= read -r copy; do
        dir="${copy%/*}"
        assert_nofile "$dir" "private copy directory removed"
        escaped=""
        for ((i=0; i<${#dir}; i++)); do
            char="${dir:i:1}"
            case "$char" in
                '.'|'['|']'|'('|')'|'{'|'}'|'*'|'+'|'?'|'^'|'$'|'|'|'\') escaped+="\\" ;;
            esac
            escaped+="$char"
        done
        assert_scan_arg "--exclude-dir=^${escaped}(/|$)" "$invocations"
        assert_scan_arg "--exclude=^${escaped}(/|$)" "$invocations"
    done < "$D/copies"
    while IFS= read -r mode; do
        assert_eq "$mode" 700 "private copy directory mode"
    done < "$D/copy-modes"
}
assert_scan_arg() {
    local arg count=0
    for arg in "${ARGS[@]}"; do [ "$arg" != "$1" ] || count=$((count + 1)); done
    assert_eq "$count" "${2:-1}" "scanner argument $1"
}
assert_mount_count() {
    local arg count=0
    for arg in "${ARGS[@]}"; do
        case "$arg" in --exclude-dir=*) count=$((count + 1)) ;; esac
    done
    # AV_EXCLUDE_DIRS, mount exclusions, and (for clamscan) its private copy.
    local copies=0
    [ ! -f "$D/copies" ] || copies="$(wc -l < "$D/copies")"
    assert_eq "$count" "$(($1 + 1 + copies))" "mount exclusion count"
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
    local copy
    while IFS= read -r copy; do
        assert_nofile "${copy%/*}" "repeated scan copy directory removed"
    done < "$D/copies"
}
row_scan_timeout() {
    scan_fixture; SCAN_ENV=(AV_SCAN_TIMEOUT=0.1s STUB_SCAN_LOOP=1)
    scan --path /scratch
    assert_eq "$RC" 124 "timeout exit distinct from threats"
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
shift 3
printf '%s\0' "$@" > "$SCAN_ARGS"
exit 137
EOF
    scan --path /scratch
    assert_eq "$RC" 137 "kill exit distinct from threats"
    assert_eq "$(grep -c "WARN.*scan was killed (SIGKILL: its time limit's kill-after, or another killer such as the OOM killer) and did not finish" <<< "$OUT")" 1 "killed unfinished warning"
    assert_lacks "$OUT" 'stopped at its time limit' "SIGKILL cause is uncertain"
}
row_scan_threats() {
    scan_fixture
    SCAN_ENV=(AV_ON_FOUND='printf "hook ran\n" >> "$CALLS"')
    stub clamscan <<'EOF'
printf '%s\0' "$@" > "$SCAN_ARGS"
exit 1
EOF
    scan --path /scratch
    assert_eq "$RC" 1 "finding exit preserved"
    assert_has "$OUT" 'THREATS FOUND' "finding logged"
    assert_has "$(calls)" 'hook ran' "AV_ON_FOUND still runs"
}

scan_vanished_fixture() {
    scan_fixture
    SCAN_ENV=(AV_SCAN_TIMEOUT=0 OUTPUT="$D/output" SCAN_RC=2)
    stub clamscan <<'STUB'
printf '%s\0' "$@" > "$SCAN_ARGS"
cat "$OUTPUT"
exit "$SCAN_RC"
STUB
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/gone1" "$D/gone2" > "$D/output"
}
scan_vanished_check() {
    scan --path "$D"
}
scan_vanished_summary() {
    printf '\n----------- SCAN SUMMARY -----------\nInfected files: 0\nTotal errors: %s\n' "${1:-2}" >> "$D/output"
}
row_scan_vanished_only() {
    scan_vanished_fixture
    scan_vanished_summary
    scan_vanished_check
    assert_eq "$RC" 0 "vanished exit"
    assert_has "$OUT" 'scan finished; 2 file(s) vanished while it ran (not scanned), no other errors' "warning"
    assert_has "$OUT" "$(cat "$D/output")" "scanner output unchanged and ordered"
    assert_nofile "$H/state/linux-av/last-good-scan.stamp" "forgiven error keeps good stamp absent"
    assert_nofile "$H/state/linux-av/last-full-scan.stamp" "forgiven error keeps full stamp absent"
}
row_scan_vanished_empty_list() {
    scan_vanished_fixture; scan_vanished_summary
    stub mktemp <<'STUB'
copy="${SCAN_ARGS%/*}/scan-copy"
mkdir "$copy"
/bin/ln -s /dev/null "$copy/vanished"
printf '%s\n' "$copy"
STUB
    scan_vanished_check
    assert_eq "$RC" 2 "empty list cannot account for warnings"
}
row_scan_vanished_unsearchable() {
    scan_vanished_fixture; mkdir "$D/locked"; touch "$D/locked/present"
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/locked/present" > "$D/output"
    scan_vanished_summary 1
    chmod 000 "$D/locked"
    scan_vanished_check
    chmod 700 "$D/locked"
    assert_eq "$RC" 2 "unsearchable parent cannot prove absence"
}
row_scan_vanished_read_failure() {
    scan_vanished_fixture; scan_vanished_summary
    cat > "$D/read-failure" <<'STUB'
read() {
    if [ "$1" = -r ] && [ "${2:-}" = line ]; then
        if [ "${READ_ONCE:-0}" = 1 ]; then return 1; fi
        READ_ONCE=1
    fi
    builtin read "$@"
}
STUB
    SCAN_ENV+=(BASH_ENV="$D/read-failure")
    scan_vanished_check
    assert_eq "$RC" 2 "partial read failure terminates and keeps error"
}
row_scan_vanished_write_failure() {
    scan_vanished_fixture; touch "$D/gone1"; scan_vanished_summary
    stub mktemp <<'STUB'
copy="${SCAN_ARGS%/*}/scan-copy"
mkdir "$copy"
/bin/ln -s /dev/full "$copy/vanished"
printf '%s\n' "$copy"
STUB
    scan_vanished_check
    assert_eq "$RC" 2 "failed vanished list write keeps error"
    assert_has "$OUT" "No space left on device" "vanished list write failed"
}
row_scan_vanished_permission() {
    scan_vanished_fixture
    printf "WARNING: Can't open file %s: Permission denied\n" "$D/denied" >> "$D/output"
    scan_vanished_summary
    scan_vanished_check
    assert_eq "$RC" 2 "permission exit"
    assert_has "$OUT" 'scanner error (rc=2)' "error logged"
}
row_scan_vanished_mismatch() {
    scan_vanished_fixture; scan_vanished_summary 3; scan_vanished_check
    assert_eq "$RC" 2 "mismatch exit"
}
row_scan_vanished_no_summary() {
    scan_vanished_fixture; printf 'Infected files: 0\nTotal errors: 2\n' >> "$D/output"; scan_vanished_check
    assert_eq "$RC" 2 "missing summary exit"
}
row_scan_vanished_reappeared() {
    scan_vanished_fixture; touch "$D/gone1"; scan_vanished_summary; scan_vanished_check
    assert_eq "$RC" 2 "reappeared exit"
}
row_scan_vanished_newline() {
    scan_vanished_fixture
    printf "WARNING: Can't open file %s\n%s: No such file or directory\n" "$D/line" 'break' > "$D/output"
    scan_vanished_summary 1
    scan_vanished_check; assert_eq "$RC" 2 "newline exit"
}
row_scan_vanished_threat() {
    scan_vanished_fixture; SCAN_ENV+=(SCAN_RC=1); scan_vanished_summary; scan_vanished_check
    assert_eq "$RC" 1 "threat exit"; assert_has "$OUT" 'THREATS FOUND' "threat warning"
}
row_scan_vanished_clamdscan() {
    scan_vanished_fixture; scan_vanished_summary
    stub clamdscan <<'STUB'
cat "$OUTPUT"
exit 2
STUB
    SCAN_ENV+=(AV_ENGINE=clamdscan); scan_vanished_check
    assert_eq "$RC" 2 "daemon error exit"
}
row_scan_vanished_split_reason() {
    scan_vanished_fixture
    local reason
    for reason in 'Permission denied' 'Input/output error' 'Operation not permitted'; do
        printf "WARNING: Can't open file %s: No such file or directory\nb: %s\n" "$D/gone" "$reason" > "$D/output"
        scan_vanished_summary 1
        scan_vanished_check
        assert_eq "$RC" 2 "split filename with $reason"
    done
}
row_scan_vanished_unknown() {
    scan_vanished_fixture
    printf 'unexpected scanner output\n' >> "$D/output"
    scan_vanished_summary; scan_vanished_check
    assert_eq "$RC" 2 "unknown line exit"
}
row_scan_vanished_infected() {
    scan_vanished_fixture; scan_vanished_summary
    sed -i 's/Infected files: 0/Infected files: 1/' "$D/output"
    scan_vanished_check; assert_eq "$RC" 2 "nonzero infections with rc 2"
}
row_scan_vanished_two_summaries() {
    scan_vanished_fixture; scan_vanished_summary
    printf '%s\n' '----------- SCAN SUMMARY -----------' >> "$D/output"
    scan_vanished_check; assert_eq "$RC" 2 "duplicate header exit"
}
row_scan_vanished_after_summary() {
    scan_vanished_fixture; scan_vanished_summary 3
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/gone3" >> "$D/output"
    scan_vanished_check; assert_eq "$RC" 2 "late vanished warning exit"
}
row_scan_vanished_found() {
    scan_vanished_fixture; scan_vanished_summary
    printf '%s\n' '/scratch/eicar: Eicar-Test-Signature FOUND' >> "$D/output"
    SCAN_ENV+=("AV_ON_FOUND=touch '$D/found'")
    scan_vanished_check; assert_eq "$RC" 2 "FOUND line with rc 2"
    # Status 2 is an error, not a threat: the text cannot raise the alert.
    assert_has "$(cat "$H/state/linux-av/av-scan.log")" 'scanner error (rc=2)' "FOUND line with rc 2 logged as an error"
    assert_lacks "$OUT" 'THREATS FOUND' "FOUND line with rc 2 reports no threat"
    assert_nofile "$D/found" "FOUND line with rc 2 runs no AV_ON_FOUND"
}
# OC-T-0084 round 3: only the scanner's status reports a threat. A file name
# holding newlines splits clamscan's can't-open warning, so a middle fragment
# can end in " FOUND" at status 2 (or even 0); that text must not alert.
row_scan_forged_found_line() {
    local status log
    for status in 2 0; do
        rm -rf -- "${WORK:?}/${ROW:?}"
        scan_vanished_fixture
        SCAN_ENV+=("SCAN_RC=$status" "AV_ON_FOUND=touch '$D/found'")
        # Name: "$D/x", LF, "fake: Eicar-Test-Signature FOUND", LF, "y"
        printf "WARNING: Can't open file %s\nfake: Eicar-Test-Signature FOUND\ny: No such file or directory\n" "$D/x" > "$D/output"
        scan_vanished_check
        log="$(cat "$H/state/linux-av/av-scan.log")"
        assert_has "$OUT" 'fake: Eicar-Test-Signature FOUND' "status $status: the forged line reached the scan output"
        assert_lacks "$OUT" 'THREATS FOUND' "status $status: forged FOUND text reports no threat"
        assert_lacks "$log" 'THREATS FOUND' "status $status: forged FOUND text logs no threat"
        assert_nofile "$D/found" "status $status: forged FOUND text runs no AV_ON_FOUND"
        if [ "$status" = 2 ]; then
            assert_eq "$RC" 2 'status 2 stays an error'
            assert_has "$log" 'scanner error (rc=2)' 'status 2 is logged as an error'
        else
            assert_eq "$RC" 0 'status 0 stays clean'
            assert_has "$log" 'clean —' 'status 0 is logged clean'
        fi
    done
}
row_scan_vanished_summary_shapes() {
    scan_vanished_fixture
    cp "$D/output" "$D/vanished"
    local line
    for line in \
        'Known viruses: x' 'Engine version: v1.5.4' \
        'Scanned directories: -1' 'Scanned files: 1 trailing' \
        'Infected files: 00' 'Total errors: 2 trailing' \
        'Data scanned: 108.33 XB' 'Data read: 90.14 GiB (ratio x:1)' \
        'Time: 33916.104 sec (565 m x s)' \
        'Start Date: 2026-11-06 11:15:34' 'End Date: 2026:11:06 20:40:50 extra' \
        'prefix Known viruses: 3628245' 'Known viruses: 3628245 suffix'; do
        cp "$D/vanished" "$D/output"; scan_vanished_summary
        printf '%s\n' "$line" >> "$D/output"
        scan_vanished_check; assert_eq "$RC" 2 "invalid summary line: $line"
    done
}
row_scan_vanished_summary_order() {
    scan_vanished_fixture
    printf 'Known viruses: 3628245\n' >> "$D/output"
    scan_vanished_summary; scan_vanished_check
    assert_eq "$RC" 2 "summary detail before header"
}
row_scan_vanished_total_order() {
    scan_vanished_fixture
    printf 'Total errors: 2\n\n----------- SCAN SUMMARY -----------\nInfected files: 0\n' >> "$D/output"
    scan_vanished_check; assert_eq "$RC" 2 "total before header"
}
row_scan_vanished_duplicate_total() {
    scan_vanished_fixture; scan_vanished_summary
    printf 'Total errors: 2\n' >> "$D/output"
    scan_vanished_check; assert_eq "$RC" 2 "duplicate total"
}
row_scan_vanished_real_summary() {
    scan_vanished_fixture
    : > "$D/output"
    local n
    for ((n=1; n<=21; n++)); do
        printf "WARNING: Can't open file %s: No such file or directory\n" "$D/gone$n" >> "$D/output"
    done
    cat >> "$D/output" <<'EOF'

----------- SCAN SUMMARY -----------
Known viruses: 3628245
Engine version: 1.5.4
Scanned directories: 453297
Scanned files: 1316902
Infected files: 0
Total errors: 21
Data scanned: 108.33 GiB
Data read: 90.14 GiB (ratio 1.20:1)
Time: 33916.104 sec (565 m 16 s)
Start Date: 2026:11:06 11:15:34
End Date:   2026:11:06 20:40:50
EOF
    scan_vanished_check; assert_eq "$RC" 0 "real 2026-11-06 output forgiven"
    assert_has "$OUT" 'scan finished; 21 file(s) vanished while it ran (not scanned), no other errors' "real scan warning"
    assert_has "$OUT" "$(cat "$D/output")" "real scanner output unchanged and ordered"
}
# OC-T-0047 round 3: every row below also fails against 4adfd96.
row_scan_vanished_stderr() {
    scan_vanished_fixture; scan_vanished_summary
    stub clamscan <<'STUB'
printf '%s\0' "$@" > "$SCAN_ARGS"
cat "$OUTPUT"
printf '%s\n' 'LibClamAV Error: read failed' >&2
exit 2
STUB
    scan_vanished_check
    assert_eq "$RC" 2 "stderr error prevents forgiveness"
    assert_has "$OUT" 'LibClamAV Error: read failed' "stderr reaches journal stream"
}
row_scan_vanished_missing_infected() {
    scan_vanished_fixture; scan_vanished_summary
    sed -i '/^Infected files:/d' "$D/output"
    scan_vanished_check; assert_eq "$RC" 2 "infected count required"
}
row_scan_vanished_duplicate_infected() {
    scan_vanished_fixture; scan_vanished_summary
    printf 'Infected files: 0\n' >> "$D/output"
    scan_vanished_check; assert_eq "$RC" 2 "duplicate infected count"
}
row_scan_vanished_duplicate_details() {
    scan_vanished_fixture
    cp "$D/output" "$D/warnings"
    local line
    for line in \
        'Known viruses: 3628245' 'Engine version: 1.5.4' \
        'Scanned directories: 453297' 'Scanned files: 1316902' \
        'Data scanned: 108.33 GiB' 'Data read: 90.14 GiB (ratio 1.20:1)' \
        'Time: 33916.104 sec (565 m 16 s)' \
        'Start Date: 2026:11:06 11:15:34' 'End Date:   2026:11:06 20:40:50'; do
        cp "$D/warnings" "$D/output"; scan_vanished_summary
        printf '%s\n%s\n' "$line" "$line" >> "$D/output"
        scan_vanished_check; assert_eq "$RC" 2 "duplicate summary kind: $line"
    done
}
row_scan_vanished_zero_then_total() {
    scan_vanished_fixture; scan_vanished_summary 0
    printf 'Total errors: 2\n' >> "$D/output"
    scan_vanished_check; assert_eq "$RC" 2 "zero total cannot hide a duplicate"
}
row_scan_vanished_physical_copy() {
    scan_vanished_fixture; scan_vanished_summary
    mkdir "$D/physical"
    ln -s "$D/physical" "$D/alias"
    SCAN_ENV+=(TMPDIR="$D/alias")
    scan_vanished_check
    assert_eq "$RC" 0 "symlinked TMPDIR scan"
    local copy
    while IFS= read -r copy; do
        case "$copy" in "$D/physical/av-scan."*/output) : ;;
            *) fail "copy and its checked exclusions must use the physical path" ;;
        esac
    done < "$D/copies"
    assert_eq "$(wc -l < "$D/copies")" 1 "one physical copy"
}
row_scan_vanished_copy_resolution_failure() {
    scan_vanished_fixture; scan_vanished_summary
    ln -s "$(command -v mktemp)" "$B/plain/mktemp"
    stub mktemp <<'STUB'
case "$*" in *av-scan-state.*) exec "${BASH_SOURCE[0]%/*}/plain/mktemp" "$@" ;; esac
printf '%s\n' "${SCAN_ARGS%/*}/missing-copy"
STUB
    scan_vanished_check
    assert_eq "$RC" 2 "copy resolution failure"
    assert_has "$OUT" 'cannot create scan output copy' "copy failure diagnostic"
    assert_lacks "$(calls)" 'clamscan ' "scanner not started without resolved copy"
}
row_scan_vanished_outside_paths() {
    scan_vanished_fixture
    printf "WARNING: Can't open file /nonexistent-outside-scan: No such file or directory\n" > "$D/output"
    scan_vanished_summary 1
    scan_vanished_check; assert_eq "$RC" 2 "outside path not probed or counted"
}
scan_scheduled_check() {
    # If run_scan becomes a subshell again, the loop must time out, never sleep.
    stub sleep </dev/null
    OUT="$("$TIMEOUT_BIN" 5s "$ENV_BIN" -i PATH="$B" HOME="$H" \
        AV_ROOT="$R" AV_CONFIG="$H/av.env" AV_COLOR=never TMPDIR="$D" \
        XDG_STATE_HOME="$H/state" XDG_CONFIG_HOME="$H/config" \
        AV_MOUNTINFO="$D/mountinfo" CALLS="$CALLS" SCAN_ARGS="$D/args" \
        AV_SCAN_TIMEOUT=0 "${SCAN_ENV[@]}" "$BASH_BIN" "$REPO/bin/av-scan" \
        --path "$D" --scheduled 1 2>&1)"
    RC=$?
}
row_scan_scheduled_no_engine() {
    scan_fixture; unstub clamscan; unstub clamdscan
    SCAN_ENV=(AV_ENGINE=auto)
    scan_scheduled_check
    assert_eq "$RC" 1 "missing engine exits scheduled runner"
    assert_has "$OUT" 'no ClamAV scanner found' "missing engine diagnostic"
    assert_lacks "$(calls)" 'sleep ' "no further scheduled iteration"
}
row_scan_scheduled_hook_exit() {
    scan_fixture
    stub clamscan <<'STUB'
printf '%s\0' "$@" > "$SCAN_ARGS"
exit 1
STUB
    SCAN_ENV=(AV_ENGINE=clamscan AV_ON_FOUND='exit 1')
    scan_scheduled_check
    assert_eq "$RC" 1 "hook exit stops scheduled runner"
    assert_has "$OUT" 'THREATS FOUND' "hook reached after finding"
    assert_lacks "$(calls)" 'sleep ' "hook stops further scheduled iterations"
}
row_scan_vanished_residual_documented() {
    assert_has "$(cat "$REPO/MASTER.md")" 'Residual: clamscan prints file names unescaped and, with --infected, counts some errors (an unreadable folder, a per-file read or engine error) without a line. A local user whose vanishing file names hold newlines and forged warnings can offset as many such errors as forged lines. ClamAV already passes files deeper than 15 folders, past --max-scantime or over --max-filesize as clean, so this adds no new way to hide a file.' "residual documented verbatim"
}

row_scan_vanished_copy_excluded() {
    scan_vanished_fixture; scan_vanished_summary
    # Regex metacharacters in TMPDIR must be escaped in both exclusions.
    local tmp="$D/copy.[x]+(y){z}^\$|?*"
    mkdir -p "$tmp"
    SCAN_ENV+=(TMPDIR="$tmp")
    scan --path "$D"
    assert_eq "$RC" 0 "copy below scanned path excluded"
    assert_eq "$(wc -l < "$D/copies")" 1 "one output copy"
}
# Read only the installer functions, never its root entrypoint.
root_install_fixture() {
    new_fixture "$ROW"
    # Bounded by the two functions themselves, so no wording elsewhere can pull install steps in.
    sed -n '/^put() {/,/^}/p; /^keep() {/,/^}/p' "$REPO/root-install.sh" > "$D/functions"
    # OC-T-0096: two headers, two closing braces, ending on one; otherwise the cut ran on into the install steps,
    # so nothing is sourced (an empty file makes every row that calls put or keep go red).
    # Every other line must be indented or blank, so no top-level statement can ever be sourced.
    if [ "$(grep -c '^put() {\|^keep() {' "$D/functions")" != 2 ] || [ "$(grep -c '^}' "$D/functions")" != 2 ] ||
        [ "$(tail -n 1 "$D/functions")" != '}' ] ||
        [ "$(grep -cv '^put() {$\|^keep() {$\|^}$\|^[[:space:]]\|^$' "$D/functions")" != 0 ]; then
        : > "$D/functions"
        fail 'root-install.sh put and keep functions are not two whole blocks'
    fi
}
# OC-T-0096: the fixture's cut is two whole functions and nothing else; this row's only red path is that guard.
row_root_install_functions_whole() {
    root_install_fixture
    assert_eq "$(grep -c '^put() {\|^keep() {' "$D/functions")" 2 'fixture holds put and keep'
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
        rm -f "$D/installed" "$D/kept" "$D/puts"
        # The fragment now spans the keep and put calls (OC-T-0067 round 6): record them, copy only the conf.
        OUT="$("$ENV_BIN" -i PATH="$B" CALLS="$CALLS" "$BASH_BIN" -c '
            set -u
            die() { echo "$*" >&2; exit 1; }
            keep() { echo "$1" >> "$t/kept"; }
            put() { echo "$1" >> "$t/puts"; case $1 in "$t/linux-av.conf") cp "$1" "$t/installed" ;; esac; }
            t="$1"; here="$t/tree"; dst="$t/dst"; source "$t/config-fragment"
        ' sh "$D" 2>&1)"; RC=$?
        assert_eq "$RC" "$status" "Perl status $status"
        if [ "$status" = 1 ]; then
            assert_nofile "$D/installed" "invalid Perl never installed"
            assert_nofile "$D/kept" "invalid Perl: nothing kept"
            assert_nofile "$D/puts" "invalid Perl: nothing put"
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
    assert_eq "$n" 3 "root-install.sh lists three rendering inputs"
}

# A scratch root, stubs for every privileged tool, and the complete installer with its root paths
# redirected into the scratch root ($D/installer); no real privileged tool runs.
root_install_scratch() {
    new_fixture "$ROW"
    mkdir -p "$R/usr/local/lib/linux-av/bin" "$R/usr/local/lib/linux-av/lib" \
        "$R/etc/systemd/system/linux-av-scan.service.d" "$R/etc/needrestart/conf.d" "$R/run"
    ln -s "$BASH_BIN" "$B/bash"
    ln -s "$(command -v sha256sum)" "$B/sha256sum"
    stub hostname <<'STUB'
echo OVH
STUB
    # OC-T-0083: the CPU cap drop-in answers with the scratch file's real mode (a row may chmod it) and the owner in
    # $D/cap-uid, since no test runs as root; every other path answers as a root-owned 0755 folder, as before.
    ln -s "$(command -v stat)" "$B/realstat"
    stub stat <<'STUB'
case "$2" in
    '%u %A')
        case "$3" in
            *R-3377-cpu-cap.conf) echo "$(cat "${CALLS%/*}/cap-uid") $(realstat -c %A "$3")" ;;
            *) echo '0 drwxr-xr-x' ;;
        esac ;;
    '%u %g %a') echo '0 0 644' ;;
    *) exit 1 ;;
esac
STUB
    # OC-T-0083: the two read-backs answer only for their exact calls, so a changed call prints nothing.
    stub systemctl <<'STUB'
case "$*" in
    'show linux-av-scan.service -p TimeoutStartUSec --value') echo '12h 30min' ;;
    'show linux-av-scan.service -p CPUQuotaPerSecUSec -p CPUWeight -p MemoryHigh -p MemoryMax')
        printf '%s\n' CPUQuotaPerSecUSec=1s CPUWeight=20 MemoryHigh=2147483648 MemoryMax=3221225472 ;;
esac
exit 0
STUB
    stub install <<'STUB'
[ "$1 $2 $3 $4 $5" = '-o root -g root -m' ] || exit 1
shift 5
mode=$1; shift
cp "$1" "$2" && chmod "$mode" "$2"
STUB
    stub perl <<'STUB'
exit 0
STUB
    sed -e 's|^PATH=.*|PATH="$B"|' \
        -e "s|/usr/local/lib|$R/usr/local/lib|g" \
        -e "s|/etc/systemd/system|$R/etc/systemd/system|g" \
        -e "s|/etc/needrestart|$R/etc/needrestart|g" \
        -e "s|/run/linux-av-root-install|$R/run/linux-av-root-install|g" \
        "$REPO/root-install.sh" > "$D/installer"
    # OC-T-0083: OVH's CPU cap drop-in, as the installer finds it: a root-owned 0644 regular file with both lines set.
    CAP="$R/etc/systemd/system/linux-av-scan.service.d/R-3377-cpu-cap.conf"
    printf '%s\n' '[Service]' 'CPUQuota=100%' 'CPUWeight=20' > "$CAP"
    chmod 0644 "$CAP"
    printf '0\n' > "$D/cap-uid"
}
# Execute a scratch copy of the complete installer, from the checkout.
row_root_install_limits() {
    root_install_scratch
    OUT="$(cd "$REPO" && "$ENV_BIN" -i B="$B" PATH="$B" HOME="$H" \
        AV_CONFIG="$H/av.env" XDG_CONFIG_HOME="$H/config" XDG_STATE_HOME="$H/state" \
        CALLS="$CALLS" /bin/sh "$D/installer" 2>&1)"; RC=$?
    assert_eq "$RC" 0 'scratch installer exit'
    local drop="$R/etc/systemd/system/linux-av-scan.service.d/limits.conf" line
    assert_file "$drop" 'limits installed'
    assert_eq "$(cat "$drop" 2>/dev/null)" "$(printf '%s\n' \
        '[Service]' MemoryHigh=2G MemoryMax=3G)" 'exact installed memory bounds; CPU owned by OVH drop-in'
    assert_eq "$(stat -c %a "$drop" 2>/dev/null)" 644 'drop-in mode'
    assert_has "$(calls)" "install -o root -g root -m 0644" 'root ownership requested'
    assert_has "$(calls)" "$drop.new" 'atomic sibling write'
    assert_nofile "$drop.new" 'atomic rename completed'
    assert_has "$OUT" "$(sha256sum < "$drop" 2>/dev/null | cut -c1-64)" 'drop-in hash recorded'
    assert_has "$(calls)" 'systemctl daemon-reload' 'daemon reload'
    # OC-T-0083: after the reload, the unit's CPU and memory bounds are read back and printed, beside the time limit.
    local show='systemctl show linux-av-scan.service -p CPUQuotaPerSecUSec -p CPUWeight -p MemoryHigh -p MemoryMax' calls_text
    calls_text="$(calls)"
    assert_has "$calls_text" "$show" 'CPU and memory bounds read back'
    assert_has "${calls_text%%"$show"*}" 'systemctl daemon-reload' 'bounds read back after the reload'
    assert_has "$OUT" 'TimeoutStartUSec=12h 30min' 'time limit still printed'
    assert_has "$OUT" "$(printf '%s\n' CPUQuotaPerSecUSec=1s CPUWeight=20 MemoryHigh=2147483648 MemoryMax=3221225472)" \
        'effective CPU and memory bounds printed'
    assert_eq "$(cat "$CAP")" "$(printf '%s\n' '[Service]' 'CPUQuota=100%' 'CPUWeight=20')" 'CPU cap drop-in left as it was'
    local call
    while IFS= read -r call; do
        case "$call" in
            'systemctl daemon-reload'|'systemctl show linux-av-scan.service -p TimeoutStartUSec --value'|"$show"|'systemctl is-active linux-av-scan.timer') ;;
            systemctl*) fail "unexpected unit action: $call" ;;
        esac
    done < "$CALLS"
    # Compare the drop-in with the existing timer renderer's defaults.
    SCAN_ENV=(); resource_install
    local unit="$R/etc/systemd/system/linux-av-scan.service"
    for line in MemoryHigh MemoryMax; do
        assert_eq "$(sed -n "/^$line=/p" "$drop" 2>/dev/null)" "$(sed -n "/^$line=/p" "$unit")" 'timer and drop-in agree'
    done
    for line in CPUQuota=100% CPUWeight=20; do
        assert_has "$(cat "$unit")" "$line" 'fresh timer retains template CPU bound'
    done
}
# OC-T-0067: /usr/local/sbin/ovh-root-run copies the tree without file modes, and run card 23989 stopped at
# the renderer call with exit 126 (Permission denied). Run the installer from a copy of the files it needs,
# itself included, with every exec bit stripped: it must render the limits without executing bin/av-scan.
row_root_install_no_exec_bits() {
    root_install_scratch
    local tree="$D/tree" f
    mkdir -p "$tree/bin" "$tree/lib" "$tree/systemd"
    cp "$REPO/bin/av-scan" "$tree/bin/av-scan"
    cp "$REPO/lib/common.sh" "$tree/lib/common.sh"
    cp "$REPO/systemd/av-scan.service" "$tree/systemd/av-scan.service"
    cp "$D/installer" "$tree/root-install.sh"
    for f in root-install.sh bin/av-scan lib/common.sh systemd/av-scan.service; do
        chmod a-x "$tree/$f"
        [ ! -x "$tree/$f" ] || fail "$f keeps an exec bit, so the copy is not the runner's"
    done
    OUT="$(cd "$tree" && "$ENV_BIN" -i B="$B" PATH="$B" HOME="$H" \
        AV_CONFIG="$H/av.env" XDG_CONFIG_HOME="$H/config" XDG_STATE_HOME="$H/state" \
        CALLS="$CALLS" /bin/sh "$tree/root-install.sh" 2>&1)"; RC=$?
    assert_eq "$RC" 0 'installer exit from a copy with no exec bits'
    assert_lacks "$OUT" 'Permission denied' 'no file run without its exec bit'
    local drop="$R/etc/systemd/system/linux-av-scan.service.d/limits.conf"
    assert_file "$drop" 'limits installed'
    assert_eq "$(cat "$drop" 2>/dev/null)" "$(printf '%s\n' \
        '[Service]' MemoryHigh=2G MemoryMax=3G)" 'exact installed memory bounds'
    assert_eq "$(stat -c %a "$R/usr/local/lib/linux-av/bin/av-scan" 2>/dev/null)" 755 \
        'installed scanner executable though its source had no exec bit'
    assert_has "$OUT" 'root-install: done' 'installer ran to its end'
}
# OC-T-0067: run card 23989 replaced av-scan and common.sh and then stopped at the renderer. A failure while
# rendering or checking must change nothing installed: here the renderer fails (an explicit memory override that
# is not a systemd size), and the installer must stop before its first keep or put.
row_root_install_render_first() {
    root_install_scratch
    local tree="$D/tree"
    mkdir -p "$tree/bin" "$tree/lib" "$tree/systemd"
    cp "$REPO/bin/av-scan" "$tree/bin/av-scan"
    cp "$REPO/lib/common.sh" "$tree/lib/common.sh"
    cp "$REPO/systemd/av-scan.service" "$tree/systemd/av-scan.service"
    cp "$D/installer" "$tree/root-install.sh"
    # An installed copy to keep, so a keep before the failure would leave a backup behind.
    local lib="$R/usr/local/lib/linux-av"
    printf 'old scanner\n' > "$lib/bin/av-scan"; printf 'old library\n' > "$lib/lib/common.sh"
    OUT="$(cd "$tree" && "$ENV_BIN" -i B="$B" PATH="$B" HOME="$H" \
        AV_CONFIG="$H/av.env" XDG_CONFIG_HOME="$H/config" XDG_STATE_HOME="$H/state" \
        AV_SCAN_MEMORY_HIGH=not-a-size CALLS="$CALLS" /bin/sh "$tree/root-install.sh" 2>&1)"; RC=$?
    assert_eq "$(cat "$lib/bin/av-scan")" 'old scanner' 'installed scanner untouched'
    assert_eq "$(cat "$lib/lib/common.sh")" 'old library' 'installed library untouched'
    assert_nofile "$lib/lib/common.sh.before-R-3377" 'no library backup made'
    [ "$RC" != 0 ] || fail 'installer went on after its renderer failed'
    assert_has "$OUT" 'AV_SCAN_MEMORY_HIGH must be a systemd size' 'the renderer is what failed'
    assert_lacks "$(calls)" 'install -o root' 'nothing installed before the failure'
    assert_lacks "$(calls)" 'systemctl' 'nothing reloaded before the failure'
    assert_nofile "$R/usr/local/lib/linux-av/bin/av-scan.before-R-3377" 'no scanner backup made'
    assert_lacks "$OUT" 'written: ' 'no file written'
    assert_lacks "$OUT" 'kept: ' 'no backup made'
    assert_lacks "$OUT" 'root-install: done' 'installer stopped'
}
# OC-T-0067: a renderer that exits 0 having printed nothing is refused, before anything is kept or installed.
row_root_install_render_empty() {
    root_install_scratch
    local tree="$D/tree"
    mkdir -p "$tree/bin" "$tree/lib" "$tree/systemd"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$tree/bin/av-scan"
    cp "$REPO/lib/common.sh" "$tree/lib/common.sh"
    cp "$REPO/systemd/av-scan.service" "$tree/systemd/av-scan.service"
    cp "$D/installer" "$tree/root-install.sh"
    # OC-T-0096: an installed copy to keep, so a keep before the guard would leave a backup behind.
    local lib="$R/usr/local/lib/linux-av"
    printf 'old scanner\n' > "$lib/bin/av-scan"; printf 'old library\n' > "$lib/lib/common.sh"
    OUT="$(cd "$tree" && "$ENV_BIN" -i B="$B" PATH="$B" HOME="$H" \
        AV_CONFIG="$H/av.env" XDG_CONFIG_HOME="$H/config" XDG_STATE_HOME="$H/state" \
        CALLS="$CALLS" /bin/sh "$tree/root-install.sh" 2>&1)"; RC=$?
    [ "$RC" != 0 ] || fail 'installer went on after an empty render'
    assert_has "$OUT" 'rendered empty' 'empty render refused'
    assert_lacks "$(calls)" 'install -o root' 'nothing installed after an empty render'
    assert_lacks "$OUT" 'kept: ' 'no backup made after an empty render'
    assert_eq "$(cat "$lib/bin/av-scan")" 'old scanner' 'installed scanner untouched after an empty render'
    assert_eq "$(cat "$lib/lib/common.sh")" 'old library' 'installed library untouched after an empty render'
    assert_nofile "$lib/bin/av-scan.before-R-3377" 'no scanner backup after an empty render'
    assert_nofile "$lib/lib/common.sh.before-R-3377" 'no library backup after an empty render'
}

# OC-T-0083: OVH's CPU cap for the scan comes from R-3377-cpu-cap.conf, which the installer never writes. Each row below
# breaks that drop-in one way and runs the scratch installer from the checkout over an installed copy of every file the
# installer writes. It must stop with the cap check's own message, run neither the installer tool nor systemctl, and leave
# the whole scratch root as it was: no backup, no new file, no changed byte. The message is asserted, so a guard that is
# removed cannot hide behind a later one that happens to refuse the same file.
root_install_tree() {
    (cd "$R" && { find . ! -type d -printf '%p %m %u %l\n'; find . -type f -exec sha256sum {} +; } | sort)
}
root_install_cap_refused() { # message
    local sd="$R/etc/systemd/system/linux-av-scan.service.d" lib="$R/usr/local/lib/linux-av" before after
    printf 'old scanner\n' > "$lib/bin/av-scan"; printf 'old library\n' > "$lib/lib/common.sh"
    printf 'old limits\n' > "$sd/limits.conf"; printf 'old time limit\n' > "$sd/30-time-limit.conf"
    printf 'old needrestart\n' > "$R/etc/needrestart/conf.d/linux-av.conf"
    before="$(root_install_tree)"
    OUT="$(cd "$REPO" && "$ENV_BIN" -i B="$B" PATH="$B" HOME="$H" \
        AV_CONFIG="$H/av.env" XDG_CONFIG_HOME="$H/config" XDG_STATE_HOME="$H/state" \
        CALLS="$CALLS" /bin/sh "$D/installer" 2>&1)"; RC=$?
    after="$(root_install_tree)"
    [ "$RC" != 0 ] || fail 'installer went on with its CPU cap drop-in broken'
    assert_has "$OUT" "$1" 'the cap check is what refused'
    assert_has "$OUT" 'nothing was installed' 'refusal says nothing was installed'
    assert_eq "$after" "$before" 'every file under the scratch root untouched'
    assert_lacks "$(calls)" 'install -o root' 'nothing installed'
    assert_lacks "$(calls)" 'systemctl' 'nothing reloaded'
    assert_lacks "$OUT" 'written: ' 'no file written'
    assert_lacks "$OUT" 'kept: ' 'no backup made'
    assert_lacks "$OUT" 'root-install: done' 'installer stopped'
}
row_root_install_cap_missing() {
    root_install_scratch; rm -f -- "$CAP"
    root_install_cap_refused 'R-3377-cpu-cap.conf is missing or not a regular file'
}
# The link points at a good file, so only the link check stands between it and the install.
row_root_install_cap_link() {
    root_install_scratch; cp -p "$CAP" "$D/cap-target"; rm -f -- "$CAP"; ln -s "$D/cap-target" "$CAP"
    root_install_cap_refused 'R-3377-cpu-cap.conf is a link'
}
row_root_install_cap_group_writable() {
    root_install_scratch; chmod 0664 "$CAP"
    root_install_cap_refused 'R-3377-cpu-cap.conf is writable by group or others (-rw-rw-r--)'
}
row_root_install_cap_other_writable() {
    root_install_scratch; chmod 0646 "$CAP"
    root_install_cap_refused 'R-3377-cpu-cap.conf is writable by group or others (-rw-r--rw-)'
}
row_root_install_cap_foreign_owner() {
    root_install_scratch; printf '1000\n' > "$D/cap-uid"
    root_install_cap_refused 'R-3377-cpu-cap.conf is not owned by root (uid 1000)'
}
# A commented line is not a setting.
row_root_install_cap_quota_missing() {
    root_install_scratch; printf '%s\n' '[Service]' '#CPUQuota=100%' 'CPUWeight=20' > "$CAP"
    root_install_cap_refused 'R-3377-cpu-cap.conf has no CPUQuota= line with a value'
}
row_root_install_cap_weight_missing() {
    root_install_scratch; printf '%s\n' '[Service]' 'CPUQuota=100%' '#CPUWeight=20' > "$CAP"
    root_install_cap_refused 'R-3377-cpu-cap.conf has no CPUWeight= line with a value'
}
# An empty assignment resets the setting in systemd, so a line without a value is as good as none.
row_root_install_cap_quota_empty() {
    root_install_scratch; printf '%s\n' '[Service]' 'CPUQuota=' 'CPUWeight=20' > "$CAP"
    root_install_cap_refused 'R-3377-cpu-cap.conf has no CPUQuota= line with a value'
}
row_root_install_cap_weight_empty() {
    root_install_scratch; printf '%s\n' '[Service]' 'CPUQuota=100%' 'CPUWeight=' > "$CAP"
    root_install_cap_refused 'R-3377-cpu-cap.conf has no CPUWeight= line with a value'
}

# OC-T-0047 round 4: the absent-now probe stays inside the kept paths and the time limit.
row_scan_vanished_dotdot() {
    scan_vanished_fixture; mkdir -p "$D/kept"
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/kept/../outside/gone" > "$D/output"
    scan_vanished_summary 1
    scan --path "$D/kept"; assert_eq "$RC" 2 "dot-dot path leaves the kept paths"
}
row_scan_vanished_symlink_component() {
    scan_vanished_fixture; mkdir -p "$D/kept" "$D/outside"
    ln -s "$D/outside" "$D/kept/d"
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/kept/d/gone" > "$D/output"
    scan_vanished_summary 1
    scan --path "$D/kept"; assert_eq "$RC" 2 "probe refuses a symlinked component"
}
row_scan_vanished_probe_bounded() {
    scan_vanished_fixture; scan_vanished_summary
    stub timeout <<'STUB'
printf 2
exit 137
STUB
    scan_vanished_check; assert_eq "$RC" 2 "a killed probe keeps the error"
    assert_has "$(calls)" 'timeout -s KILL 60s ' "probe runs under its own kill limit"
}
row_scan_vanished_relative_full() {
    scan_vanished_fixture; mkdir -p "$D/cwd" "$D/outside"
    ln -s "$D/outside" "$D/cwd/link"
    printf "WARNING: Can't open file %s: No such file or directory\n" "link/gone" > "$D/output"
    scan_vanished_summary 1
    local oldpwd="$PWD"
    cd "$D/cwd" || return 1
    scan --full
    cd "$oldpwd" || return 1
    assert_eq "$RC" 2 "relative path rejected under full scan"
}
row_scan_vanished_absolute_full() {
    scan_vanished_fixture
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/gone" > "$D/output"
    scan_vanished_summary 1
    scan --full; assert_eq "$RC" 0 "absolute vanished path under full scan"
}
row_scan_vanished_skipped_mount() {
    scan_vanished_fixture; mkdir -p "$D/kept/m"
    mount_entry "$D/kept/m" fuse.sshfs
    printf 'exec %q "$@"\n' "$TIMEOUT_BIN" | stub timeout
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/kept/m/gone" > "$D/output"
    scan_vanished_summary 1
    scan --path "$D/kept"; assert_eq "$RC" 2 "no probe below a skipped mount"
    assert_lacks "$(calls)" 'timeout -s KILL' "probe not started below a skipped mount"
}
row_scan_vanished_noncanonical() {
    scan_vanished_fixture; mkdir -p "$D/kept/m"
    mount_entry "$D/kept/m" fuse.sshfs
    printf 'exec %q "$@"\n' "$TIMEOUT_BIN" | stub timeout
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/kept/./m/gone" > "$D/output"
    scan_vanished_summary 1
    scan --path "$D/kept"; assert_eq "$RC" 2 "a /./ spelling is refused"
    printf "WARNING: Can't open file %s: No such file or directory\n" "$D/kept//m/gone" > "$D/output"
    scan_vanished_summary 1
    scan --path "$D/kept"; assert_eq "$RC" 2 "a // spelling is refused"
    assert_lacks "$(calls)" 'timeout -s KILL' "no probe for a non-canonical path"
}
row_installer_hash_lines() {
    local line hash path count=0 actual
    while IFS= read -r line; do
        count=$((count + 1))
        if [[ ! $line =~ ^\#\ sha256\ ([0-9a-f]{64})\ ([A-Za-z0-9._+/-]+)$ ]]; then
            fail "malformed sha256 line: $line"
            continue
        fi
        hash=${BASH_REMATCH[1]}; path=${BASH_REMATCH[2]}
        actual=$(sha256sum "$REPO/$path") || { fail "cannot hash $path"; continue; }
        assert_eq "${actual%% *}" "$hash" "sha256 of $path"
    done < <(grep -E '^[[:space:]]*#[[:space:]]*sha256' "$REPO/root-install.sh")
    [ "$count" -gt 0 ] || fail "no sha256 lines found"
}
# OC-T-0067: resource limits, scratch pruning, and incremental scans.
resource_install() {
    OUT="$("$ENV_BIN" -i PATH="$B" HOME="$H" AV_ROOT="$R" AV_CONFIG="$H/av.env" \
        AV_COLOR=never TMPDIR="$D" XDG_STATE_HOME="$H/state" CALLS="$CALLS" \
        "${SCAN_ENV[@]}" "$BASH_BIN" "$REPO/bin/av-scan" --install-timer 86400000 2>&1)"; RC=$?
}
row_scan_memory_defaults() {
    scan_fixture; resource_install
    assert_eq "$RC" 0 'render exit'
    local unit; unit="$(cat "$R/etc/systemd/system/linux-av-scan.service" 2>/dev/null)"
    local line; for line in MemoryHigh=2G MemoryMax=3G CPUQuota=100% CPUWeight=20 Nice=10 IOSchedulingClass=idle; do
        assert_has "$unit" "$line" 'resource bound'
    done
}
row_scan_memory_values() {
    scan_fixture
    local value unit
    for value in 12 4K 50M 6G 1T infinity ''; do
        SCAN_ENV=(AV_SCAN_MEMORY_HIGH= "AV_SCAN_MEMORY_MAX=$value"); resource_install
        assert_eq "$RC" 0 "accepted size $value"
        unit="$(cat "$R/etc/systemd/system/linux-av-scan.service" 2>/dev/null)"
        assert_lacks "$unit" 'MemoryHigh=' 'empty high omitted'
        if [ -n "$value" ]; then assert_has "$unit" "MemoryMax=$value" 'max rendered'
        else assert_lacks "$unit" 'MemoryMax=' 'empty max omitted'; fi
    done
}
row_scan_memory_invalid() {
    scan_fixture
    local name value
    for name in AV_SCAN_MEMORY_HIGH AV_SCAN_MEMORY_MAX; do
        for value in 1GB -1 1.5G $'2G\nExecStart=bad' '1G|bad' ''; do
            [ -n "$value" ] || continue
            SCAN_ENV=("$name=$value"); resource_install
            [ "$RC" -ne 0 ] || fail "accepted invalid $name"
            assert_has "$OUT" "$name" 'clear validation error'
            assert_nofile "$R/etc/systemd/system/linux-av-scan.service" 'no service written'
            assert_nofile "$R/etc/systemd/system/linux-av-scan.timer" 'no timer written'
            assert_lacks "$(calls)" 'systemctl ' 'no systemctl on invalid size'
        done
    done
}
row_scan_scratch_components() {
    scan_fixture; printf 'AV_EXCLUDE_PATTERNS="target a.b .claude/worktrees"\n' >> "$H/av.env"
    scan --path "$D/tree"
    local arg regex found=0
    for arg in "${ARGS[@]}"; do
        [[ $arg = '--exclude-dir=(^|/)target(/|$)' ]] || continue
        regex=${arg#--exclude-dir=}; found=1
        [[ /x/target/child =~ $regex ]] || fail 'target tree included'
        [[ ! /x/targets/child =~ $regex && ! /x/mytarget/child =~ $regex ]] || fail 'partial component excluded'
    done
    assert_eq "$found" 1 'whole component expression'
    assert_scan_arg '--exclude-dir=(^|/)a\.b(/|$)'
    assert_scan_arg '--exclude-dir=(^|/)\.claude/worktrees(/|$)'
}
row_scan_scratch_defaults() {
    scan_fixture; sed -i '/^AV_EXCLUDE_PATTERNS=/d' "$H/av.env"; scan --path "$D"
    local name
    for name in node_modules target __pycache__; do assert_scan_arg "--exclude-dir=(^|/)$name(/|$)"; done
    assert_scan_arg '--exclude-dir=(^|/)\.cache(/|$)'
}
changed_fixture() {
    scan_fixture; ln -s "$(command -v find)" "$B/find"
    sed -i '/^AV_EXCLUDE_PATTERNS=/d' "$H/av.env"
    sed -i '/^AV_FULL_EVERY=/d' "$H/av.env"
    mkdir -p "$D/tree" "$H/state/linux-av"
    L="$H/state/linux-av"
    stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
for arg in "$@"; do
    case "$arg" in --file-list=*)
        f=${arg#--file-list=}; printf '%s\n' "$f" > "${SCAN_ARGS%/*}/list-path"
        stat -c '%a' "$f" > "${SCAN_ARGS%/*}/list-mode"
        cat "$f" > "${SCAN_ARGS%/*}/list" ;;
    esac
done
exit "${SCAN_RC:-0}"
STUB
}
changed_seed() {
    touch -d '2 days ago' "$L/last-full-scan.stamp"
    touch -d '1 day ago' "$L/last-good-scan.stamp"
}
row_scan_changed_selection() {
    changed_fixture; changed_seed
    touch "$D/tree/new" "$D/tree/metadata"
    touch -d '10 days ago' "$D/tree/metadata"
    mkdir -p "$D/tree/target" "$D/tree/targets" "$D/tree/.claude/worktrees" "$D/tree/cloud" "$D/tree/legacy"
    touch "$D/tree/target/no" "$D/tree/targets/yes" "$D/tree/.claude/worktrees/no" "$D/tree/cloud/no" "$D/tree/legacy/no"
    printf 'AV_EXCLUDE_DIRS="%s/tree/legacy"\n' "$D" >> "$H/av.env"
    mount_entry "$D/tree/cloud" cifs
    scan --path "$D/tree"
    assert_eq "$RC" 0 'changed exit'
    assert_has "$OUT" 'mode=changed' 'automatic changed mode'
    local list; list="$(cat "$D/list" 2>/dev/null)"
    assert_has "$list" "$D/tree/new" 'mtime change'
    assert_has "$list" "$D/tree/metadata" 'ctime change'
    assert_has "$list" "$D/tree/targets/yes" 'near match kept'
    assert_lacks "$list" '/target/no' 'scratch pruned'
    assert_lacks "$list" '/worktrees/no' 'multi component pruned'
    assert_lacks "$list" '/cloud/no' 'mount pruned'
    assert_lacks "$list" '/legacy/no' 'legacy pruned'
    assert_eq "$(cat "$D/list-mode" 2>/dev/null)" 600 'private list'
    assert_nofile "$(cat "$D/list-path" 2>/dev/null)" 'list cleaned'
    assert_file "$L/last-good-scan.stamp" 'good stamp'
}
row_scan_changed_empty() {
    changed_fixture; changed_seed
    scan --path "$D/tree"
    assert_eq "$RC" 0 'empty changed exit'
    assert_has "$OUT" 'nothing changed' 'empty report'
    assert_lacks "$(calls)" 'clamscan ' 'no engine needed for empty list'
    [ "$L/last-good-scan.stamp" -nt "$L/last-full-scan.stamp" ] || fail 'stamp advanced'
}
row_scan_changed_modes() {
    changed_fixture
    scan --path "$D/tree"
    assert_has "$OUT" 'mode=full' 'first scan full'
    assert_file "$L/last-full-scan.stamp" 'full stamp'
    touch -d '9 days ago' "$L/last-full-scan.stamp"
    scan --path "$D/tree"
    assert_has "$OUT" 'mode=full' 'expired full'
    changed_seed; scan --full-scan --path "$D/tree"
    assert_eq "$RC" 0 'forced full exit'; assert_has "$OUT" 'forced' 'forced reason'; assert_has "$OUT" 'mode=full' 'forced full'
    rm -f "$L/last-full-scan.stamp"; touch "$D/tree/a"
    scan --changed --path "$D/tree"
    assert_eq "$RC" 0 'forced changed exit'; assert_has "$OUT" 'mode=changed' 'forced changed without full stamp'
}
row_scan_changed_intervals() {
    changed_fixture; changed_seed
    local duration
    for duration in 1 1m 1h 1d; do
        SCAN_ENV=("AV_FULL_EVERY=$duration"); scan --path "$D/tree"
        assert_has "$OUT" 'mode=full' "expired interval $duration"; changed_seed
    done
    SCAN_ENV=(AV_FULL_EVERY=8d); scan --path "$D/tree"; assert_has "$OUT" 'mode=changed' 'fresh interval'
    SCAN_ENV=(AV_FULL_EVERY=bogus); scan --path "$D/tree"
    [ "$RC" -ne 0 ] || fail 'invalid duration accepted'
    assert_has "$OUT" 'AV_FULL_EVERY' 'invalid interval diagnostic'
}
row_scan_changed_stamps() {
    changed_fixture
    local rc
    for rc in 0 1 2 124 137 143; do
        rm -f "$L/last-full-scan.stamp" "$L/last-good-scan.stamp"
        SCAN_ENV=("SCAN_RC=$rc"); scan --path "$D/tree"
        assert_eq "$RC" "$rc" "scanner exit $rc"
        if [ "$rc" -le 1 ]; then
            assert_file "$L/last-full-scan.stamp" "full completed $rc"
            assert_file "$L/last-good-scan.stamp" "scan completed $rc"
        else
            assert_nofile "$L/last-full-scan.stamp" "full incomplete $rc"
            assert_nofile "$L/last-good-scan.stamp" "scan incomplete $rc"
        fi
    done
}
# OC-T-0067 round 2: control characters stay single, literal argv entries.
row_scan_changed_newline() {
    changed_fixture; changed_seed
    local name="$D/tree/"$'new\nline'
    touch "$name" "$D/tree/plain"
    scan --path "$D/tree"
    assert_eq "$RC" 0 'newline scan completes'
    assert_scan_arg "$name"
    assert_has "$(cat "$D/list" 2>/dev/null)" "$D/tree/plain" 'ordinary file still scanned'
    assert_lacks "$(cat "$D/list" 2>/dev/null)" "$name" 'newline kept off file-list'
    [ "$L/last-good-scan.stamp" -nt "$L/last-full-scan.stamp" ] || fail 'complete walk advances stamp'
}
row_scan_changed_cr() {
    changed_fixture; changed_seed
    local name="$D/tree/evil"$'\r' arg file seen=()
    touch "$name" "$D/tree/evil"
    scan --path "$D/tree"
    assert_eq "$RC" 0 'CR scan completes'
    assert_scan_arg "$name"
    # Model the file-list reader's possible CR stripping, plus literal argv.
    while IFS= read -r file; do seen+=("${file%$'\r'}"); done < "$D/list"
    for arg in "${ARGS[@]}"; do case "$arg" in /*) seen+=("$arg") ;; esac; done
    ARGS=("${seen[@]}")
    assert_scan_arg "$name"
    assert_scan_arg "$D/tree/evil"
}
# OC-T-0067 round 3: model fgets(buffer, 1024), including relative split targets.
row_scan_changed_long_names() {
    changed_fixture; changed_seed
    local LC_ALL=C dir="$D/tree" part prefix name size
    printf -v part '%0180d' 0
    while [ "${#dir}" -lt 850 ]; do dir="$dir/$part"; done
    mkdir -p "$dir"
    printf -v part '%*s' "$((1023 - ${#dir} - 1))" ''
    prefix="$dir/${part// /x}"
    assert_eq "${#prefix}" 1023 'split prefix length in bytes'
    printf 'clean\n' > "$prefix"
    printf 'malware\n' > "${prefix}decoy"
    printf 'clean\n' > "$D/decoy"
    # Exercise the conservative boundary, with a UTF-8 name whose byte and
    # character lengths differ. The scanner itself runs under a UTF-8 locale.
    for size in 1021 1022; do
        name="${prefix:0:size-2}"$'\xc3\xa9'
        printf 'clean\n' > "$name"
    done
    stub clamscan <<'STUB'
export LC_ALL=C
printf '%s\0' "$@" >> "$SCAN_ARGS"
cd "${SCAN_ARGS%/*}" || exit 2
rc=0
check_target() {
    local target="$1"
    [[ $target = /* ]] || target="$PWD/$target"
    printf '%s\0' "$target" >> scanned
    if [ -f "$target" ] && [ "$(cat "$target")" = malware ]; then
        printf '%s: Test.Signature FOUND\n' "$target"; rc=1
    fi
}
for arg in "$@"; do
    case "$arg" in
        --file-list=*)
            cat "${arg#--file-list=}" >> list
            while IFS= read -r -n 1023 file || [ -n "$file" ]; do
                [ -z "$file" ] || check_target "${file%$'\r'}"
            done < "${arg#--file-list=}" ;;
        /*) check_target "$arg" ;;
    esac
done
exit "$rc"
STUB
    SCAN_ENV=(LC_ALL=C.utf8)
    scan --path "$D/tree"
    assert_eq "$RC" 1 'crafted long target detected as itself'
    assert_has "$OUT" 'THREATS FOUND' 'long target threat reported'
    assert_scan_arg "$prefix"
    assert_scan_arg "${prefix}decoy"
    name="${prefix:0:1020}"$'\xc3\xa9'
    assert_scan_arg "$name"
    assert_lacks "$(cat "$D/list" 2>/dev/null)" "$name" '1022-byte name kept off file-list'
    name="${prefix:0:1019}"$'\xc3\xa9'
    assert_has "$(cat "$D/list" 2>/dev/null)" "$name" '1021-byte name still uses file-list'
    local -a seen=()
    mapfile -d '' -t seen < "$D/scanned"
    for name in "${seen[@]}"; do
        [ "$name" != "$D/decoy" ] || fail 'relative decoy substituted for long target'
    done
    ARGS=("${seen[@]}"); assert_scan_arg "${prefix}decoy"
}
row_scan_changed_found_error() {
    changed_fixture; changed_seed
    touch "$D/tree/plain" "$D/tree/odd"$'\n'
    stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
rc=$ODD_RC
for arg in "$@"; do case "$arg" in --file-list=*) rc=$NORMAL_RC ;; esac; done
if [ "$rc" = 1 ]; then echo 'test: Test.Signature FOUND'
else echo "WARNING: Can't open file ${SCAN_ARGS%/*}/tree/gone: No such file or directory"; fi
exit "$rc"
STUB
    local normal odd error order
    for error in 2 126 137 139; do
        for order in found_first error_first; do
            if [ "$order" = found_first ]; then normal=1; odd=$error
            else normal=$error; odd=1; fi
            changed_seed
            cp -p "$L/last-good-scan.stamp" "$D/good-before"
            cp -p "$L/last-full-scan.stamp" "$D/full-before"
            rm -f "$D/found"
            : > "$L/av-scan.log"
            SCAN_ENV=("NORMAL_RC=$normal" "ODD_RC=$odd" "AV_ON_FOUND=touch '$D/found'")
            scan --changed --path "$D/tree"
            assert_eq "$RC" 1 "threat wins with ordinary batch rc=$normal"
            assert_has "$OUT" 'THREATS FOUND' 'mixed result reports threat'
            assert_file "$D/found" 'mixed result invokes AV_ON_FOUND'
            assert_has "$(cat "$L/av-scan.log")" 'THREATS FOUND' 'threat persisted in log'
            assert_has "$(cat "$L/av-scan.log")" "clamscan batch failed (rc=$error)" 'batch error remains visible in log'
            assert_has "$(cat "$L/av-scan.log")" 'stamps unchanged' 'batch failure holds stamps in log'
            assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" "threat plus rc=$error keeps good stamp ($order)"
            assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" "threat plus rc=$error keeps full stamp ($order)"
        done
    done
}
# OC-T-0067 round 4: PATH_MAX bounds both routes, counted in bytes.
row_scan_changed_unscannable() {
    changed_fixture; changed_seed
    local LC_ALL=C name prefix quoted found arg
    prefix="/"$'unsafe\n\r\t\'"\\'"/${D#/}/tree/"
    printf -v name '%*s' "$((4096 - ${#prefix} - 2))" ''
    name="$prefix${name// /x}"$'\xc3\xa9'
    printf -v quoted '%q' "${name:0:80}"
    printf '%s\0' "$name" > "$D/unscannable"
    printf -v name '%131072s' ''
    name="/$name"; name="${name:0:131072}"
    printf '%s\0' "$name" >> "$D/unscannable"
    printf -v name '%4095s' ''
    name="/${name:1}"; name="${name// /x}"
    printf '%s\0' "$name" > "$D/scannable"
    printf 'malware\n' > "$D/tree/plain"
    stub find <<'STUB'
cat "${SCAN_ARGS%/*}/walk"
STUB
    stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
for arg in "$@"; do
    case "$arg" in --file-list=*)
        cat "${arg#--file-list=}" >> "${SCAN_ARGS%/*}/list"
        while IFS= read -r file; do
            if [ "$(cat "$file")" = malware ]; then
                echo 'plain: Test.Signature FOUND'; exit 1
            fi
        done < "${arg#--file-list=}" ;;
    esac
done
exit 0
STUB
    # Empty remainder, clean batch-mates, and an ordinary threat all hold stamps.
    for found in empty clean threat; do
        changed_seed
        cp -p "$L/last-good-scan.stamp" "$D/good-before"
        cp -p "$L/last-full-scan.stamp" "$D/full-before"
        cp "$D/unscannable" "$D/walk"
        if [ "$found" != empty ]; then cat "$D/scannable" >> "$D/walk"; fi
        if [ "$found" = threat ]; then printf '%s\0' "$D/tree/plain" >> "$D/walk"; fi
        : > "$D/args"; : > "$L/av-scan.log"; rm -f "$D/found"
        SCAN_ENV=(LC_ALL=C.utf8 "AV_ON_FOUND=touch '$D/found'")
        scan --changed --path "$D/tree"
        assert_eq "$RC" 2 "unscannable path forces error ($found)"
        assert_has "$OUT" "unscannable path (4096 bytes): $quoted" 'byte length and safely quoted prefix reported'
        assert_has "$OUT" 'unscannable path (131072 bytes):' 'oversized argv rejected before exec'
        assert_has "$(cat "$L/av-scan.log")" "unscannable path (4096 bytes): $quoted" 'unscannable persisted in log'
        assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" "unscannable keeps good stamp ($found)"
        assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" "unscannable keeps full stamp ($found)"
        for arg in "${ARGS[@]}"; do
            [ "${#arg}" -lt 4096 ] || fail 'unscannable path reached argv'
        done
        if [ "$found" != empty ]; then assert_scan_arg "$name"; fi
        if [ "$found" = threat ]; then
            assert_has "$(cat "$D/list")" "$D/tree/plain" 'ordinary batch-mate scanned'
            assert_has "$OUT" 'THREATS FOUND' 'ordinary threat still reported'
            assert_file "$D/found" 'ordinary threat invokes AV_ON_FOUND'
        fi
    done
}
row_scan_changed_vanishing_folder() {
    changed_fixture; changed_seed
    touch "$D/tree/kept"
    mkdir "$D/tree/gone"
    cp -p "$L/last-good-scan.stamp" "$D/good-before"
    cp -p "$L/last-full-scan.stamp" "$D/full-before"
    # Deterministic race at the find boundary: preserve output from the walk,
    # then remove a discovered folder and return the traversal failure.
    printf 'real_find=%q\n' "$(command -v find)" > "$D/find-path"
    stub find <<'STUB'
source "${SCAN_ARGS%/*}/find-path"
"$real_find" "$@"
rm -r "${SCAN_ARGS%/*}/tree/gone"
echo 'find: folder vanished mid-walk' >&2
exit 1
STUB
    scan --path "$D/tree"
    assert_eq "$RC" 2 'partial coverage remains an error'
    assert_has "$(cat "$D/list" 2>/dev/null)" "$D/tree/kept" 'listed file scanned despite race'
    assert_has "$(calls)" '-ignore_readdir_race' 'find tolerates readdir races'
    assert_has "$OUT" 'partial walk' 'partial walk reported'
    assert_has "$OUT" 'stamps unchanged' 'retry rule reported'
    assert_has "$(cat "$L/av-scan.log")" 'partial walk' 'partial walk persisted in log'
    assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" 'good stamp unchanged'
    assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" 'full stamp unchanged'
    assert_lacks "$OUT" 'clean —' 'failed walk never logs clean'
    assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'failed walk closes with error'

}
# OC-T-0080 (FAULT-0017): odd names batch by bytes. A name costs its bytes (counted under LC_ALL=C), its NUL and an
# 8-byte pointer, and a run takes names until 1 MiB (1048576) is reached, the name that reaches it included.
#   4000-byte names cost 4009: 262 fill a run (261 reach 1046349). d158e91's limit of 8192 characters made it 3 names.
#   3955-byte names of 1980 characters cost 3964: 265 fill a run (264 reach 1046496). Counted as characters, 528 would.
#   260 short names fit one run, where d158e91's limit of 128 names made three.
# The names come through a find stub, so no file system holds them; the scanner stub counts the names of each run.
row_scan_changed_odd_batches() {
    changed_fixture
    local LC_ALL=C pad name first second shape count want edge i
    stub find <<'STUB'
cat "${SCAN_ARGS%/*}/walk"
STUB
    stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
n=0
for arg in "$@"; do case "$arg" in /*) n=$((n + 1)) ;; esac; done
echo "$n" >> "${SCAN_ARGS%/*}/sizes"
STUB
    SCAN_ENV=(LC_ALL=C.utf8)
    for shape in ascii utf8 short; do
        changed_seed
        : > "$D/walk"; : > "$D/sizes"
        count=540; edge=0
        case $shape in
            ascii) printf -v pad '%3995s' ''; pad=${pad// /x}; want='262 262 16'; edge=262 ;;
            utf8) printf -v pad '%1975s' ''; pad=${pad// /$'\xc3\xa9'}; want='265 265 10'; edge=265 ;;
            short) pad=''; want=260; count=260; edge=130 ;;
        esac
        # The first name, the first of the second run, and the last: each reaches a scanner once.
        for ((i=0; i<count; i++)); do
            if [ "$shape" = short ]; then name="$D/tree/odd-$i"$'\n'; else printf -v name '/%04d%s' "$i" "$pad"; fi
            [ "$i" != 0 ] || first=$name
            [ "$i" != "$edge" ] || second=$name
            printf '%s\0' "$name" >> "$D/walk"
        done
        scan --changed --path "$D/tree"
        assert_eq "$RC" 0 "$shape: every batch completes"
        assert_eq "$(tr '\n' ' ' < "$D/sizes")" "$want " "$shape: names in each run"
        assert_scan_arg "$first"
        assert_scan_arg "$second"
        assert_scan_arg "$name"
    done
}
# OC-T-0081 (FAULT-0019): a changed scan with odd names runs the scanner more than once, and each run has an output of
# its own and a status of its own. batch_run K STATUS ERRORS [GONE...] writes run K's output as clamscan 1.5.4 prints
# it, a warning for each file named and then the summary, with a Total errors line when ERRORS is not 0, and the
# status the scanner stub returns for the run. The stub counts its runs in $D/run, answers run K with $D/out.K, with
# $D/err.K on stderr if that exists, and with the status in $D/status.K.
batch_run() {
    local k="$1" status="$2" errors="$3" gone
    shift 3
    : > "$D/out.$k"
    for gone; do printf "WARNING: Can't open file %s: No such file or directory\n" "$gone" >> "$D/out.$k"; done
    printf '\n----------- SCAN SUMMARY -----------\nKnown viruses: 3628245\nEngine version: 1.5.4\nScanned directories: 1\nScanned files: 3\nInfected files: 0\n' >> "$D/out.$k"
    [ "$errors" = 0 ] || printf 'Total errors: %s\n' "$errors" >> "$D/out.$k"
    printf 'Data scanned: 0.00 MiB\nData read: 0.00 MiB (ratio 0.00:1)\nTime: 0.100 sec (0 m 0 s)\nStart Date: 2026:11:17 19:00:00\nEnd Date:   2026:11:17 19:00:00\n' >> "$D/out.$k"
    printf '%s\n' "$status" > "$D/status.$k"
}
batch_fixture() {
    changed_fixture; changed_seed
    touch "$D/tree/plain" "$D/tree/odd"$'\n'
    stub clamscan <<'STUB'
d=${SCAN_ARGS%/*}
printf '%s\0' "$@" >> "$SCAN_ARGS"
k=1; [ ! -f "$d/run" ] || k=$(($(cat "$d/run") + 1))
echo "$k" > "$d/run"
[ -f "$d/out.$k" ] || exit 99
cat "$d/out.$k"
[ ! -f "$d/err.$k" ] || cat "$d/err.$k" >&2
exit "$(cat "$d/status.$k")"
STUB
    cp -p "$L/last-good-scan.stamp" "$D/good-before"
    cp -p "$L/last-full-scan.stamp" "$D/full-before"
}
batch_reset() { rm -f "$D"/run "$D"/out.* "$D"/err.* "$D"/status.*; : > "$L/av-scan.log"; }
# The ordinary file and the LF-named one make two runs: the file-list run, then one batch. Vanished files in either
# run, or in both, are forgiven when every run's summary matches its own warnings; the stamps stay where they were.
# At d158e91 the worker held the stamps for any batch of status 2, and its two summaries would have failed the whitelist.
row_scan_changed_batch_vanished() {
    batch_fixture
    local gone="$D/tree/gone" scenario count pad i
    for scenario in listed odd many; do
        batch_reset
        case $scenario in
            listed) batch_run 1 2 1 "$gone-a"; batch_run 2 0 0; count=1 ;;
            odd) batch_run 1 0 0; batch_run 2 2 1 "$gone-a"; count=1 ;;
            many)
                # The file-list run and two batches (262 and 38 names of 4000 bytes), each with errors of its own.
                stub find <<'STUB'
cat "${SCAN_ARGS%/*}/walk"
STUB
                printf '%s\0' "$D/tree/plain" > "$D/walk"
                printf -v pad '%3995s' ''; pad=${pad// /x}
                for ((i=0; i<300; i++)); do printf '/%04d%s\0' "$i" "$pad" >> "$D/walk"; done
                batch_run 1 2 2 "$gone-a" "$gone-b"; batch_run 2 2 1 "$gone-c"; batch_run 3 0 0; count=3 ;;
        esac
        scan --changed --path "$D/tree"
        assert_eq "$RC" 0 "$scenario: vanished files in several runs are forgiven"
        assert_has "$OUT" "scan finished; $count file(s) vanished while it ran (not scanned), no other errors" "$scenario: the vanished files are counted"
        assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" "$scenario: good stamp kept"
        assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" "$scenario: full stamp kept"
    done
}
# The worker reports a batch that returned 2 on its own stderr and in the log. Those lines are not scanner output, so
# they are not what the whitelist reads, and the vanished file is still forgiven; both lines still reach the reader.
row_scan_changed_batch_worker_line() {
    batch_fixture; batch_reset
    batch_run 1 0 0; batch_run 2 2 1 "$D/tree/gone"
    scan --changed --path "$D/tree"
    assert_eq "$RC" 0 'the worker line is not a scanner error'
    assert_has "$OUT" 'scan finished; 1 file(s) vanished while it ran (not scanned), no other errors' 'the vanished file is forgiven'
    assert_has "$OUT" 'ERROR: clamscan batch failed (rc=2)' 'the worker line reaches the output'
    assert_has "$(cat "$L/av-scan.log")" 'ERROR: clamscan batch failed (rc=2)' 'the worker line reaches the log'
}
# Each case holds a run of status 2 with a vanished file (forgiven alone) beside a second run with something else
# wrong, and nothing is forgiven: the error stays at status 2, the log says the batch failed, the stamps stay.
#   offset      the totals add up (2 and 2) but not run by run (a total of 1 for 2 warnings, then 1 for none)
#   unexplained a run of status 2 whose summary lists no error
#   hard        the second run failed outright (137) after printing a clean summary; the merged status keeps the 2
#   text        a run prints a line the whitelist does not know
#   stderr      the line is on the run's stderr
#   no_summary  a run of status 2 has a warning and no summary
#   duplicate   a run prints two summaries
#   clean_lists a run of status 0 lists an error and a warning
#   tee_failed  every copy of a run fails to be written, so the runs' statuses are unknown
row_scan_changed_batch_errors() {
    batch_fixture
    local gone="$D/tree/gone" scenario
    for scenario in offset unexplained hard text stderr no_summary duplicate clean_lists tee_failed; do
        batch_reset
        batch_run 1 2 1 "$gone-a"
        case $scenario in
            offset) batch_run 1 2 1 "$gone-a" "$gone-b"; batch_run 2 2 1 ;;
            unexplained) batch_run 2 2 0 ;;
            hard) batch_run 2 137 0 ;;
            text) batch_run 2 0 0; printf 'LibClamAV Warning: the database is old\n' >> "$D/out.2" ;;
            stderr) batch_run 2 0 0; printf 'LibClamAV Error: read failed\n' > "$D/err.2" ;;
            no_summary) printf "WARNING: Can't open file %s: No such file or directory\n" "$gone-b" > "$D/out.2"; printf '2\n' > "$D/status.2" ;;
            duplicate) batch_run 2 0 0; cat "$D/out.2" "$D/out.2" > "$D/out.dup"; mv "$D/out.dup" "$D/out.2" ;;
            clean_lists) batch_run 2 0 1 "$gone-b" ;;
            tee_failed)
                batch_run 2 0 0
                stub tee <<'STUB'
printf '%s\n' "$1" >> "${SCAN_ARGS%/*}/copies"
stat -c '%a' "${1%/*}" >> "${SCAN_ARGS%/*}/copy-modes"
"${BASH_SOURCE[0]%/*}/plain/tee" "$@"
case "$1" in */run.*) exit 1 ;; esac
STUB
                ;;
        esac
        scan --changed --path "$D/tree"
        assert_eq "$RC" 2 "$scenario: the error stays"
        assert_lacks "$OUT" 'vanished while it ran' "$scenario: nothing is forgiven"
        assert_has "$(cat "$L/av-scan.log")" 'clamscan batch failed; stamps unchanged so the next run retries' "$scenario: the batch failure is logged"
        assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" "$scenario: good stamp kept"
        assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" "$scenario: full stamp kept"
    done
}
row_scan_changed_odd_timeout() {
    changed_fixture; changed_seed
    touch "$D/tree/normal" "$D/tree/odd"$'\r'
    stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
sleep 0.2
STUB
    ln -s "$(command -v sleep)" "$B/sleep"
    cp -p "$L/last-good-scan.stamp" "$D/good-before"
    SCAN_ENV=(AV_SCAN_TIMEOUT=0.3s)
    scan --path "$D/tree"
    assert_eq "$RC" 124 'all batches share one timeout'
    assert_has "$OUT" 'time limit' 'timeout reported'
    assert_eq "$(stat -c %Y "$L/last-good-scan.stamp")" "$(stat -c %Y "$D/good-before")" 'timeout keeps old stamp'
}
row_scan_changed_odd_error() {
    changed_fixture; changed_seed
    touch "$D/tree/plain" "$D/tree/odd"$'\n'
    stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
for arg in "$@"; do case "$arg" in --file-list=*) exit 2 ;; esac; done
exit 0
STUB
    cp -p "$L/last-good-scan.stamp" "$D/good-before"
    scan --path "$D/tree"
    assert_scan_arg "$D/tree/odd"$'\n'
    assert_eq "$RC" 2 'later clean batch cannot erase an earlier error'
    assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" 'mixed results keep stamp'
}
row_scan_changed_daemon() {
    changed_fixture; changed_seed; touch "$D/tree/new"
    SCAN_ENV=(AV_ENGINE=clamdscan); scan --path "$D/tree"
    assert_has "$OUT" 'changed scans require clamscan' 'daemon switch reason'
    assert_has "$(calls)" 'clamscan ' 'standalone used'
    : > "$CALLS"; unstub clamscan; changed_seed
    scan --path "$D/tree"
    assert_eq "$RC" 0 'fallback full exit'
    assert_has "$OUT" 'falling back to full' 'fallback logged'
    assert_has "$(calls)" 'clamdscan ' 'daemon full used'
    assert_file "$L/last-full-scan.stamp" 'fallback full stamp'
}
row_scan_changed_pruning() {
    changed_fixture; changed_seed
    printf 'AV_EXCLUDE_PATTERNS="target a.b a*b"\n' >> "$H/av.env"
    mkdir -p "$D/tree/x" "$D/tree/a.b" "$D/tree/axb" "$D/tree/a*b" "$D/tree/azb" "$D/tree/target"
    touch "$D/tree/x/target" "$D/tree/a.b/no" "$D/tree/axb/yes" "$D/tree/a*b/no" "$D/tree/azb/yes" "$D/tree/target/no"
    chmod 000 "$D/tree/target"
    scan --path "$D/tree"
    chmod 700 "$D/tree/target"
    assert_eq "$RC" 0 'excluded tree never entered'
    local list; list="$(cat "$D/list" 2>/dev/null)"
    assert_has "$list" '/x/target' 'regular file named target kept'
    assert_has "$list" '/axb/yes' 'dot escaped'
    assert_has "$list" '/azb/yes' 'asterisk escaped'
    assert_lacks "$list" '/a.b/no' 'literal dot tree pruned'
    assert_lacks "$list" '/a*b/no' 'literal asterisk tree pruned'
    changed_seed; printf 'AV_EXCLUDE_PATTERNS=""\n' >> "$H/av.env"
    scan --path "$D/tree"
    assert_has "$(cat "$D/list" 2>/dev/null)" '/target/no' 'empty disables patterns'
}
row_scan_changed_report_failure() {
    changed_fixture; mkdir "$D/report-directory"
    SCAN_ENV=("AV_LOG_FILE=$D/report-directory")
    scan --path "$D/tree"
    assert_eq "$RC" 2 'report failure exit'
    assert_has "$OUT" 'scan report could not be written' 'report failure diagnostic'
    assert_nofile "$L/last-good-scan.stamp" 'report failure keeps scan stamp absent'
    assert_nofile "$L/last-full-scan.stamp" 'report failure keeps full stamp absent'
}
row_scan_changed_walk_failure() {
    changed_fixture; changed_seed
    cp -p "$L/last-good-scan.stamp" "$D/good-before"
    scan --path "$D/missing"
    assert_eq "$RC" 2 'walk failure exit'
    assert_has "$OUT" 'changed-files walk failed' 'walk failure diagnostic'
    assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" 'failed walk leaves stamp unchanged'
    assert_lacks "$(calls)" 'clamscan ' 'incomplete walk not scanned'
    assert_lacks "$OUT" 'clean —' 'failed walk never logs clean'
    assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'failed walk closes with error'

    assert_has "$OUT" 'incomplete scan: no scannable files remain' 'empty failed walk diagnosed'

}
row_scan_changed_snapshot() {
    changed_fixture
    stub clamscan <<'STUB'
printf '%s\0' "$@" > "$SCAN_ARGS"
touch "${SCAN_ARGS%/*}/tree/during-scan"
STUB
    scan --path "$D/tree"
    assert_eq "$RC" 0 'snapshot full exit'
    [ "$D/tree/during-scan" -nt "$L/last-good-scan.stamp" ] || fail 'stamp must refer to scan start'
    stub clamscan <<'STUB'
for arg in "$@"; do case "$arg" in --file-list=*) cat "${arg#--file-list=}" > "${SCAN_ARGS%/*}/list" ;; esac; done
printf '%s\0' "$@" > "$SCAN_ARGS"
STUB
    scan --path "$D/tree"
    assert_has "$(cat "$D/list" 2>/dev/null)" '/during-scan' 'change during previous scan retained'
}
# OC-T-0084: reporting, bounded diagnostics and conservative completion.
row_scan_batch_marker_failure() {
    case $D in "$WORK"/?*) rm -rf -- "$D" ;; esac
    changed_fixture; changed_seed
    touch "$D/tree/plain" "$D/tree/odd"$'\n'
    stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
for arg in "$@"; do
    case "$arg" in --file-list=*)
        f=${arg#--file-list=}
        [ -f "${f%/*}/odd.pending" ] || exit 3
        echo 'plain: Test.Signature FOUND'; exit 1 ;;
    esac
done
exit 2
STUB
    cp -p "$L/last-good-scan.stamp" "$D/good-before"
    cp -p "$L/last-full-scan.stamp" "$D/full-before"
    SCAN_ENV=("AV_ON_FOUND=touch '$D/found'")
    scan --changed --path "$D/tree"
    assert_eq "$RC" 1 'failed marker write cannot erase threat'
    assert_file "$D/found" 'threat hook retained'
    assert_has "$(cat "$L/av-scan.log")" 'THREATS FOUND' 'threat logged'
    assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" 'good stamp retained'
    assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" 'full stamp retained'
    assert_has "$(cat "$L/av-scan.log")" 'stamps unchanged' 'failure holds stamps'
}
row_scan_pending_create_failure() {
    changed_fixture; changed_seed
    cp -p "$L/last-good-scan.stamp" "$D/good-before"
    cp -p "$L/last-full-scan.stamp" "$D/full-before"
    stub find <<'STUB'
for state in "$HOME/state/linux-av"/av-scan-state.*; do mkdir "$state/odd.pending"; done
printf '%s\0' "${SCAN_ARGS%/*}/tree/odd"$'\n'
STUB
    scan --changed --path "$D/tree"
    assert_eq "$RC" 2 'pending create failure stops scan'
    assert_has "$OUT" 'cannot create batch pending marker' 'pending create error diagnosed'
    assert_lacks "$(calls)" 'clamscan ' 'pending create failure calls no scanner'
    assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" 'good stamp retained'
    assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" 'full stamp retained'
    assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'pending failure closes with error'
}
# The stub swaps the batch marker for a directory, so rm cannot remove it and the
# marker stays in place. A batch status of 1 (threat) stays 1, alerts once and
# holds the stamps; a batch status of 0 has no threat to keep, so the failure is
# an error (2) that holds the stamps and never logs clean.
row_scan_pending_remove_failure() {
    local status log
    for status in 1 0; do
        rm -rf -- "${WORK:?}/${ROW:?}"
        changed_fixture; changed_seed
        touch "$D/tree/plain" "$D/tree/odd"$'\n'
        cp -p "$L/last-good-scan.stamp" "$D/good-before"
        cp -p "$L/last-full-scan.stamp" "$D/full-before"
        stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
for arg in "$@"; do case "$arg" in --file-list=*)
    f=${arg#--file-list=}; rm "${f%/*}/odd.pending"; mkdir "${f%/*}/odd.pending"
    [ "$BATCH_RC" != 1 ] || echo 'plain: Test.Signature FOUND'
    exit "$BATCH_RC" ;;
esac; done
exit 0
STUB
        SCAN_ENV=("BATCH_RC=$status" "AV_ON_FOUND=touch '$D/found'")
        scan --changed --path "$D/tree"
        log="$(cat "$L/av-scan.log")"
        assert_has "$log" 'clamscan batch failed; stamps unchanged so the next run retries' "status $status: the marker left in place holds the stamps"
        assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" "status $status: good stamp retained"
        assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" "status $status: full stamp retained"
        if [ "$status" = 1 ]; then
            assert_eq "$RC" 1 'pending removal failure after a threat keeps status 1'
            assert_file "$D/found" 'pending removal failure after a threat runs AV_ON_FOUND'
            assert_has "$OUT" 'THREATS FOUND' 'pending removal failure after a threat reports it'
            assert_eq "$(printf '%s\n' "$log" | grep -c 'THREATS FOUND')" 1 'threat logged once'
            assert_lacks "$log" 'scanner error' 'status 1 is not a scanner error'
            assert_lacks "$log" 'scan failed' 'status 1 does not close as a failed scan'
        else
            assert_eq "$RC" 2 'pending removal failure without a threat is an error'
            assert_nofile "$D/found" 'pending removal failure without a threat runs no hook'
            assert_lacks "$log" 'THREATS FOUND' 'no threat is reported'
            assert_lacks "$log" 'clean —' 'held scan never logs clean'
            assert_has "$log" 'scanner error (rc=2)' 'pending removal failure logs the error'
            assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'pending removal failure closes with error'
        fi
    done
}
row_scan_state_marker_failure() {
    local marker status
    for marker in threat completed; do
        for status in 1 124; do
            [ "$marker:$status" != completed:124 ] || continue
            case $D in "$WORK"/?*) rm -rf -- "$D" ;; esac
            changed_fixture; changed_seed
            cp -p "$L/last-good-scan.stamp" "$D/good-before"
            cp -p "$L/last-full-scan.stamp" "$D/full-before"
            ln -s "$(command -v touch)" "$B/plain/touch"
            stub touch <<'STUB'
for arg in "$@"; do case "$arg" in */av-scan-state.*/"$FAIL_MARKER") exit 1 ;; esac; done
exec "${BASH_SOURCE[0]%/*}/plain/touch" "$@"
STUB
            stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
echo 'plain: Test.Signature FOUND'
exit "$SCAN_RC"
STUB
            SCAN_ENV=("FAIL_MARKER=$marker" "SCAN_RC=$status" "AV_ON_FOUND=touch '$D/found'; rc=0; walk_failed=0; unscannable=0")
            scan --full-scan --path "$D/tree"
            [ "$status" -gt 1 ] || status=2
            assert_eq "$RC" "$status" 'marker failure preserves error or stop status'
            assert_file "$D/found" 'marker failure retains alert'
            assert_has "$OUT" 'THREATS FOUND' 'marker failure reports threat'
            assert_has "$OUT" "cannot write $marker marker" 'marker error diagnosed'
            assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" 'good stamp retained'
            assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" 'full stamp retained'
            assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'marker failure closes with error'
        done
    done
}
row_scan_completion_marker_failure() {
    local mode
    for mode in empty daemon partial; do
        case $D in "$WORK"/?*) rm -rf -- "$D" ;; esac
        changed_fixture; changed_seed
        cp -p "$L/last-good-scan.stamp" "$D/good-before"
        cp -p "$L/last-full-scan.stamp" "$D/full-before"
        ln -s "$(command -v touch)" "$B/plain/touch"
        ln -s "$(command -v rm)" "$B/plain/rm"
        stub touch <<'STUB'
for arg in "$@"; do case "$arg" in */av-scan-state.*/completed) [ "$MARKER_MODE" = partial ] || exit 1 ;; esac; done
exec "${BASH_SOURCE[0]%/*}/plain/touch" "$@"
STUB
        stub rm <<'STUB'
for arg in "$@"; do case "$arg" in */av-scan-state.*/completed)
    if [ "$MARKER_MODE" = partial ]; then
        [ ! -e "$arg" ] || touch "$HOME/unexpected-completed"
        exit 1
    fi ;;
esac; done
exec "${BASH_SOURCE[0]%/*}/plain/rm" "$@"
STUB
        SCAN_ENV=("MARKER_MODE=$mode" "AV_ON_FOUND=touch '$D/found'")
        case $mode in
            empty)
                stub find <<'STUB'
exit 0
STUB
                scan --changed --path "$D/tree" ;;
            daemon)
                unstub clamscan
                stub clamdscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
exit 1
STUB
                SCAN_ENV+=(AV_ENGINE=clamdscan)
                scan --full-scan --path "$D/tree" ;;
            partial)
                stub find <<'STUB'
printf '%s\0' "${SCAN_ARGS%/*}/tree/plain"
exit 1
STUB
                SCAN_ENV+=(SCAN_RC=1)
                scan --changed --path "$D/tree" ;;
        esac
        assert_eq "$RC" 2 'completion marker failure fails scan'
        assert_nofile "$H/unexpected-completed" 'incomplete coverage never creates completion marker'
        if [ "$mode" != empty ]; then
            assert_file "$D/found" 'completion marker failure retains alert'
            assert_has "$OUT" 'THREATS FOUND' 'completion marker failure reports threat'
        fi
        assert_lacks "$OUT" 'clean —' 'failed completion never logs clean'
        assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'completion failure closes with error'
        assert_eq "$(stat -c %y "$L/last-good-scan.stamp")" "$(stat -c %y "$D/good-before")" 'good stamp retained'
        assert_eq "$(stat -c %y "$L/last-full-scan.stamp")" "$(stat -c %y "$D/full-before")" 'full stamp retained'
    done
}
row_scan_hook_status_isolation() {
    unscannable_fixture
    printf '%s\0' "$D/tree/plain" >> "$D/walk"
    SCAN_ENV=(SCAN_RC=1 "AV_ON_FOUND=touch '$D/found'; rc=0; walk_failed=0; unscannable=0")
    scan --changed --path "$D/tree"
    assert_eq "$RC" 2 'hook cannot clear incomplete coverage'
    assert_file "$D/found" 'hook still runs'
    assert_lacks "$OUT" 'clean —' 'hook cannot produce clean report'
    assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'hook cannot clear closing error'
}
row_scan_stamp_failure_closing() {
    local stamp
    for stamp in full good; do
        case $D in "$WORK"/?*) rm -rf -- "$D" ;; esac
        changed_fixture
        ln -s "$(command -v touch)" "$B/plain/touch"
        stub touch <<'STUB'
for arg in "$@"; do case "$arg" in */av-scan-state.*/"$FAIL_STAMP") exit 1 ;; esac; done
exec "${BASH_SOURCE[0]%/*}/plain/touch" "$@"
STUB
        SCAN_ENV=("FAIL_STAMP=$stamp")
        scan --full-scan --path "$D/tree"
        assert_eq "$RC" 2 'stamp write failure fails scan'
        assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'stamp failure closes with error'
        assert_eq "$(grep -c 'scan failed (rc=' "$L/av-scan.log")" 1 'one closing error'
    done
}
unscannable_fixture() {
    changed_fixture; changed_seed
    local name
    printf -v name '%4096s' ''; name="/${name:1}"
    printf '%s\0' "$name" > "$D/walk"
    stub find <<'STUB'
cat "${SCAN_ARGS%/*}/walk"
STUB
}
row_scan_unscannable_closing() {
    local status
    for status in 0 1 124 137 143; do
        case $D in "$WORK"/?*) rm -rf -- "$D" ;; esac
        unscannable_fixture
        printf '%s\0' "$D/tree/plain" >> "$D/walk"
        SCAN_ENV=("SCAN_RC=$status")
        scan --changed --path "$D/tree"
        if [ "$status" -le 1 ]; then status=2; fi
        assert_eq "$RC" "$status" 'unscannable preserves scanner failure status'
        assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'last log line is error'
        assert_lacks "$OUT" 'clean —' 'incomplete coverage never logs clean'
    done
}
row_scan_unscannable_limit() {
    unscannable_fixture
    local name i
    name="$(cat "$D/walk" | tr -d '\000')"
    for ((i=1; i<25; i++)); do printf '%s\0' "$name" >> "$D/walk"; done
    scan --changed --path "$D/tree"
    assert_eq "$RC" 2 'unscannable-only run fails'
    assert_eq "$(grep -c 'unscannable path (' "$L/av-scan.log")" 20 'only first 20 paths logged'
    assert_has "$(cat "$L/av-scan.log")" '25 unscannable paths; first 20 logged' 'total count logged'
}
row_scan_summary_errors_hold() {
    changed_fixture
    stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
echo 'plain: Test.Signature FOUND'
printf '\n----------- SCAN SUMMARY -----------\nInfected files: 1\nTotal errors: 0002\n'
exit 1
STUB
    SCAN_ENV=("AV_ON_FOUND=touch '$D/found'")
    scan --full-scan --path "$D/tree"
    assert_eq "$RC" 1 'summary error retains threat status'
    assert_file "$D/found" 'summary error retains alert'
    assert_nofile "$L/last-good-scan.stamp" 'summary errors hold good stamp'
    assert_nofile "$L/last-full-scan.stamp" 'summary errors hold full stamp'
    assert_has "$OUT" 'clamscan summary reports errors' 'summary error diagnosed'
}
row_scan_threat_before_stop() {
    local status
    for status in 124 137 143; do
        case $D in "$WORK"/?*) rm -rf -- "$D" ;; esac
        changed_fixture; changed_seed
        stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
echo 'plain: Test.Signature FOUND'
exit "$SCAN_RC"
STUB
        SCAN_ENV=("SCAN_RC=$status" "AV_ON_FOUND=touch '$D/found'")
        scan --full-scan --path "$D/tree"
        assert_eq "$RC" "$status" 'stop status retained'
        assert_file "$D/found" 'threat before stop alerts'
        assert_has "$(cat "$L/av-scan.log")" 'THREATS FOUND' 'threat before stop logged'
        assert_has "$(tail -n 1 "$L/av-scan.log")" 'ERROR' 'stop closes with error'
    done
    case $D in "$WORK"/?*) rm -rf -- "$D" ;; esac
    changed_fixture; changed_seed
    touch "$D/tree/plain" "$D/tree/odd"$'\n'
    ln -s "$(command -v sleep)" "$B/sleep"
    stub clamscan <<'STUB'
printf '%s\0' "$@" >> "$SCAN_ARGS"
for arg in "$@"; do case "$arg" in --file-list=*) echo 'plain: Test.Signature FOUND'; exit 1 ;; esac; done
sleep 5
STUB
    SCAN_ENV=(AV_SCAN_TIMEOUT=0.2s "AV_ON_FOUND=touch '$D/found'")
    scan --changed --path "$D/tree"
    assert_eq "$RC" 124 'real worker timeout retained'
    assert_file "$D/found" 'earlier batch threat alerts after real timeout'
    assert_has "$(cat "$L/av-scan.log")" 'THREATS FOUND' 'earlier batch threat logged'
}
row_scan_empty_remainder_hold() {
    unscannable_fixture
    scan --changed --path "$D/tree"
    assert_eq "$RC" 2 'empty remainder holds stamps'
    assert_lacks "$OUT" 'clean —' 'empty remainder never clean'
    assert_lacks "$(calls)" 'clamscan ' 'empty remainder needs no engine'
}

# Keep OC-T-0084 mutants here: tests/mutants.sh is outside this card's edit scope.
row_scan_low_mutants() {
    local spec name expr rows dir out killed=0 survived=0
    local -a mutations=(
        'incomplete_completion_written~/^    if \[ "$rc" -le 1 \] \&\& \[ -n "${scan_state:-}" \]/s/ \&\& \[ "$walk_failed" = 0 \] \&\& \[ "$unscannable" = 0 \]//~scan_completion_marker_failure'
        'threat_marker_alert_lost~/^            report_scan_threat$/d~scan_state_marker_failure'
        'completed_marker_early_return~/touch "$scan_state\/completed".*rc=2;.*}/c\        touch "$scan_state/completed" || return 2~scan_state_marker_failure'
        'daemon_marker_early_return~/touch "$scan_state\/completed".*threat_known/c\            touch "$scan_state/completed" || return 2~scan_completion_marker_failure'
        'remove_marker_early_return~/rm -f -- "$scan_state\/completed".*threat_known/c\            rm -f -- "$scan_state/completed" || return 2~scan_completion_marker_failure'
        'empty_clean_before_marker~/touch "$scan_state\/completed".*return 2;/i\            log_info "clean — nothing changed"~scan_completion_marker_failure'
        'pending_create_ignored~/cannot create batch pending marker/c\        : > "$odd_list.pending" || true~scan_pending_create_failure'
        'pending_remove_ignored~s/|| { \[ "$rc" = 1 \] \&\& return 1; return 2; }/|| true/~scan_pending_remove_failure'
        'pending_remove_status_flattened~s/|| { \[ "$rc" = 1 \] \&\& return 1; return 2; }/|| return 2/~scan_pending_remove_failure'
        'pending_check_file_only~s/\[ -e "$odd_list.pending" \]/[ -f "$odd_list.pending" ]/~scan_pending_remove_failure'
        'found_search_unconditional~s/{ \[ "$rc" -ge 124 \] \&\& grep -Eq/{ grep -Eq/~scan_forged_found_line'
        'found_search_unconditional_vanished~s/{ \[ "$rc" -ge 124 \] \&\& grep -Eq/{ grep -Eq/~scan_vanished_found'
        'found_search_at_stop_removed~s/{ \[ "$rc" -ge 124 \] \&\& grep -Eq .* "$copy"; }/false/~scan_threat_before_stop'
        'walk_clean_guard_removed~s/if \[ "$walk_failed" = 0 \] \&\& \[ "$unscannable" = 0 \]; then log_info/if [ "$unscannable" = 0 ]; then log_info/~scan_changed_vanishing_folder'
        'empty_walk_diagnostic_removed~/incomplete scan: no scannable files remain/c\            [ "$walk_failed" = 0 ] && [ "$unscannable" = 0 ] || return 2~scan_changed_walk_failure'
        'hook_scope_shared~s/( \[ -n "${AV_ON_FOUND:-}" \] \&\& eval "$AV_ON_FOUND" )/[ -n "${AV_ON_FOUND:-}" ] \&\& eval "$AV_ON_FOUND"/~scan_hook_status_isolation'
        'stamp_closing_error_removed~/log_err "scan failed (rc=/d~scan_stamp_failure_closing'
        'pending_missing~ /: > "$odd_list.pending" ||/d~scan_batch_marker_failure'
        'pending_cleared_on_failure~s/if \[ "$failed" = 0 \]; then/if true; then/~scan_batch_marker_failure'
        'unscannable_cap_removed~/\[ "$unscannable_count" -le 20 \] || return 1/d~scan_unscannable_limit'
        'unscannable_status_flattened~s/^            0|1)/            *)/~scan_unscannable_closing'
        'summary_errors_ignored~s/\&\& grep -Eq \x27\^Total errors:/\&\& false -Eq \x27^Total errors:/~scan_summary_errors_hold'
        'earlier_threat_lost~s/touch "$scan_state\/threat"/true/~scan_threat_before_stop'
        'empty_remainder_hold_removed~/\[ "$walk_failed" = 0 \] \&\& \[ "$unscannable" = 0 \] ||/c\            :~scan_empty_remainder_hold'
        'closing_error_removed~/log_err "scan failed (rc=/d~scan_threat_before_stop'
    )
    for spec in "${mutations[@]}"; do
        IFS='~' read -r name expr rows <<< "$spec"
        dir="$WORK/m-$name"
        mkdir -p "$dir"
        cp -r "$REPO/bin" "$REPO/lib" "$REPO/tests" "$dir/"
        # Prove the row green before judging its mutation.
        if ! out="$(TMPDIR="$dir" AV_TEST_KEEP=0 AV_REPO_UNDER_TEST="$dir" "$BASH_BIN" "$dir/tests/run.sh" "$rows" 2>&1)"; then
            fail "$name baseline failed: $out"; continue
        fi
        sed -i "$expr" "$dir/bin/av-scan"
        if ! "$BASH_BIN" -n "$dir/bin/av-scan" || cmp -s "$REPO/bin/av-scan" "$dir/bin/av-scan"; then
            fail "$name invalid or not applied"; survived=$((survived + 1)); continue
        fi
        out="$(TMPDIR="$dir" AV_TEST_KEEP=0 AV_REPO_UNDER_TEST="$dir" "$BASH_BIN" "$dir/tests/run.sh" "$rows" 2>&1)"
        case "$out" in
            *"FAIL $rows:"*) printf 'killed       %s red: %s\n' "$name" "$rows"; killed=$((killed + 1)) ;;
            *) fail "$name survived: $out"; survived=$((survived + 1)) ;;
        esac
    done
    printf 'OC-T-0084 mutants: %d killed, %d survived\n' "$killed" "$survived"
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
