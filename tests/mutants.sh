#!/usr/bin/env bash
# tests/mutants.sh — removes each guard of the new code in a scratch copy of the
# checkout and shows the named tests/run.sh row(s) go red. A mutant that leaves its
# rows green SURVIVED, and the script exits 1.
#
#   tests/mutants.sh           run every mutant
#   tests/mutants.sh NAME ...  run the named mutants only
#
# The checkout itself is never changed: each mutant is applied to a copy under
# $TMPDIR. The copies are left in place (AV_TEST_KEEP=1 is passed to the rows);
# the scratch directory is $TMPDIR/linux-av-mutants.XXXXXX.

set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/linux-av-mutants.XXXXXX")" || exit 2

# NAME~FILE~SED-EXPRESSION~ROWS that must go red (space-separated)
MUTANTS=(
'mailer_guard~lib/reports.sh~s/^    if av_have_mailer; then/    if false; then/~mail_untouched_with_mail mail_untouched_with_sendmail'
'mail_tool_mail_only~lib/reports.sh~s/^av_have_mailer() { have mail || have sendmail; }/av_have_mailer() { have sendmail; }/~mail_untouched_with_mail'
'mail_tool_sendmail_only~lib/reports.sh~s/^av_have_mailer() { have mail || have sendmail; }/av_have_mailer() { have mail; }/~mail_untouched_with_sendmail'
'quiet_optout~lib/reports.sh~s/"${AV_QUIET_REPORTS:-1}" = 0/"${AV_QUIET_REPORTS:-1}" = 9/~mail_optout'
'bak_first_only~lib/reports.sh~s/^    \[ -e "$file.linux-av.bak" \] || cp -p/    cp -p/~mail_bak_first_only'
'bak_missing~lib/reports.sh~s/^    \[ -e "$file.linux-av.bak" \] || cp -p "$file" "$file.linux-av.bak"/    :/~mail_edits_applied'
'noop_when_right~lib/reports.sh~s/^    \[ "$cur" = "$line" \] \&\& return 0/    :/~mail_edit_idempotent'
'append_when_absent~lib/reports.sh~s/^    if \[ -n "$cur" \]; then/    if true; then/~mail_append_when_absent'
'append_newline~lib/reports.sh~s/^        \[ -z "$(tail -c 1 "$file")" \] || printf .\\n. >> "$file"/        :/~mail_append_when_absent'
'aide_own_mailcmd~lib/reports.sh~s/^    if \[ -n "$cur" \] \&\& \[ "$cur" != ":" \]; then/    if false; then/~aide_custom_mailcmd_kept'
'chkrootkit_mailto_edit~lib/reports.sh~/chkrootkit.conf)" MAILTO/d~mail_edits_applied'
'aide_mailcmd_edit~lib/reports.sh~s/av_set_var "$aide_cfg" MAILCMD .":".$/:/~mail_edits_applied'
'rkhunter_report_edit~lib/reports.sh~/REPORT_EMAIL .""./d~mail_edits_applied'
'call_quiet_reports~bin/av-setup~/^    av_quiet_reports$/d~mail_edits_applied'
'call_rkhunter_daily~bin/av-setup~/^    av_rkhunter_daily$/d~rkhunter_daily_on'
'call_chkrootkit_baseline~bin/av-setup~/^    av_chkrootkit_baseline || true$/d~chkrootkit_baseline_adopted'
'call_report_status~bin/av-setup~/^    av_report_status$/d~status_baseline_absent'
'cmd_chkrootkit_baseline~bin/av-setup~/^    chkrootkit-baseline) av_chkrootkit_baseline ;;/d~chkrootkit_baseline_command'
'baseline_running_guard~lib/reports.sh~s/^    if systemctl is-active --quiet "$unit.service" 2>\/dev\/null; then/    if false; then/~baseline_running_not_twice'
'baseline_detached~lib/reports.sh~s/^    elif have systemd-run; then/    elif false; then/~baseline_detached_debian baseline_detached_arch baseline_timeout_env'
'baseline_fallback~lib/reports.sh~s/^    elif have systemd-run; then/    elif true; then/~baseline_foreground_without_systemd_run'
'baseline_arch_command~lib/reports.sh~s/^        cmd=(sh -c .aide --init \&\& mv -f "$1" "$2". sh "$dir\/aide.db.new.gz" "$dir\/aide.db.gz")/        cmd=(aideinit -y -f)/~baseline_detached_arch'
'baseline_watch_hint~lib/reports.sh~/journalctl -u $unit -f/d~baseline_detached_debian'
'baseline_no_database_note~lib/reports.sh~/reports \\"no database\\" until/d~baseline_detached_debian'
'aide_init_0~bin/av-setup~s/"${AV_AIDE_INIT:-1}" = 0/"${AV_AIDE_INIT:-1}" = 9/~baseline_skip_aide_init_0'
'dropin_prefix~bin/av-setup~s/dropdir="$(av_path \/etc\/systemd\/system)\/${t}.d"/dropdir="\/etc\/systemd\/system\/${t}.d"/~baseline_timer_dropin_in_root'
'rkhunter_debian_only~lib/reports.sh~s/^    \[ "$AV_FAMILY" = debian \] || return 0/    :/~baseline_detached_arch'
'rkhunter_optout~lib/reports.sh~s/"${AV_RKHUNTER_DAILY:-1}" = 0/"${AV_RKHUNTER_DAILY:-1}" = 9/~rkhunter_optout'
'rkhunter_daily_edit~lib/reports.sh~/CRON_DAILY_RUN .*"true"/d~rkhunter_daily_on'
'rkhunter_update_edit~lib/reports.sh~/CRON_DB_UPDATE .*"true"/d~rkhunter_daily_on'
'propupd_guard~lib/reports.sh~s/have rkhunter \&\& \[ ! -e "$(av_path \/var\/lib\/rkhunter\/db\/rkhunter.dat)" \]/have rkhunter/~rkhunter_propupd_skipped_with_database'
'propupd_call~lib/reports.sh~s/rkhunter --propupd >\/dev\/null 2>&1/true/~rkhunter_propupd_when_no_database'
'cron_warning~lib/reports.sh~s/^    if have systemctl \&\& ! systemctl cat cron.service/    if false \&\& ! systemctl cat cron.service/~rkhunter_warns_without_cron'
'cron_either_or~lib/reports.sh~s/^                      \&\& ! systemctl cat crond/                      || ! systemctl cat crond/~rkhunter_warns_without_cron'
'chk_existing_guard~lib/reports.sh~s/^    if \[ -e "$expected" \]; then/    if false; then/~chkrootkit_baseline_keeps_existing'
'chk_empty_guard~lib/reports.sh~s/^    if \[ ! -s "$today" \]; then/    if false; then/~chkrootkit_baseline_needs_a_run'
'chk_infected_guard~lib/reports.sh~s/grep -Eq .INFECTED|Vulnerable. "$today"/grep -Eq "Vulnerable" "$today"/~chkrootkit_baseline_infected'
'chk_vulnerable_guard~lib/reports.sh~s/grep -Eq .INFECTED|Vulnerable. "$today"/grep -Eq "INFECTED" "$today"/~chkrootkit_baseline_vulnerable'
'chk_finding_status~lib/reports.sh~s/^        return 1$/        return 0/~chkrootkit_baseline_infected'
'status_baseline_building~lib/reports.sh~s/^    if have systemctl \&\& systemctl is-active --quiet "$unit.service" 2>\/dev\/null; then/    if false; then/~status_baseline_building'
'status_baseline_present~lib/reports.sh~s/^    elif \[ -n "$db" \]; then/    elif false; then/~status_baseline_present'
'status_rkhunter_on~lib/reports.sh~s/^        \[YyTt\]\*) printf .  rkhunter daily run:  on\\n. ;;/        [YyTt]*) printf "  rkhunter daily run:  off\\n" ;;/~status_reports_quiet'
'status_mail_off~lib/reports.sh~s/^    if \[ -f "$(av_path \/etc\/chkrootkit\/chkrootkit.conf)" \] \&\& \[ -z "$v" \]; then/    if false; then/~status_reports_quiet'
'status_mail_kept~lib/reports.sh~s/^    if \[ -f "$(av_path \/etc\/chkrootkit\/chkrootkit.conf)" \] \&\& \[ -z "$v" \]; then/    if true; then/~status_reports_mail_kept'
'status_chk_baseline~lib/reports.sh~s/^    if \[ -e "$(av_path \/var\/log\/chkrootkit\/log.expected)" \]; then/    if false; then/~status_chkrootkit_baseline'
'status_rkhunter_db~lib/reports.sh~s/^    if \[ -e "$(av_path \/var\/lib\/rkhunter\/db\/rkhunter.dat)" \]; then/    if false; then/~status_rkhunter_off'
)

SELECT=" $* "
KILLED=0; SURVIVED=0

# The unmutated copy must be green for every row first, or "red" would mean nothing.
copy_to() { # dir
    mkdir -p "$1"
    cp -r "$REPO/bin" "$REPO/lib" "$REPO/tests" "$1/"
    [ -d "$REPO/config" ] && cp -r "$REPO/config" "$1/"
}
run_rows() { # dir rows...
    local dir="$1"; shift
    AV_TEST_KEEP=1 TMPDIR="$WORK" "$dir/tests/run.sh" "$@" 2>&1
}

copy_to "$WORK/clean"
if ! out="$(run_rows "$WORK/clean")"; then
    printf '%s\n' "$out" | tail -n 20
    echo "the unmutated copy is not green; no mutant can be judged"
    exit 1
fi
printf 'unmutated: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"

for m in "${MUTANTS[@]}"; do
    IFS='~' read -r name file expr rows <<EOF
$m
EOF
    case "$SELECT" in "  ") : ;; *" $name "*) : ;; *) continue ;; esac
    dir="$WORK/m-$name"
    copy_to "$dir"
    sed -i "$expr" "$dir/$file"
    if ! bash -n "$dir/$file"; then
        printf 'INVALID      %s (the mutant does not parse)\n' "$name"
        SURVIVED=$((SURVIVED + 1)); continue
    fi
    if cmp -s "$REPO/$file" "$dir/$file"; then
        printf 'NOT APPLIED  %s (the pattern matched nothing in %s)\n' "$name" "$file"
        SURVIVED=$((SURVIVED + 1)); continue
    fi
    # shellcheck disable=SC2086
    out="$(run_rows "$dir" $rows)"
    missing=""
    for r in $rows; do
        case "$out" in *"FAIL $r:"*) : ;; *) missing="$missing $r" ;; esac
    done
    if [ -z "$missing" ]; then
        printf 'killed       %-26s red: %s\n' "$name" "$rows"
        KILLED=$((KILLED + 1))
    else
        printf 'SURVIVED     %-26s still green:%s\n' "$name" "$missing"
        SURVIVED=$((SURVIVED + 1))
    fi
done
printf '%d killed, %d survived\n' "$KILLED" "$SURVIVED"
[ "$SURVIVED" -eq 0 ]
