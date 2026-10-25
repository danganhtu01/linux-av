#!/usr/bin/env bash
# shellcheck shell=bash
# lib/reports.sh — where the scanners' reports go, and the one-time baselines.
#
# Sourced by bin/av-setup after lib/common.sh. Debian/Ubuntu first; the AIDE
# baseline also covers Arch.
#
# Why this exists (raspberrypi5, first night, 2026-10-25): no machine in the fleet
# has a mailer, so chkrootkit-daily (mail), dailyaidecheck (mail) and rkhunter's
# cron job (sendmail) either failed or sent nothing anywhere. A real finding
# reached no one. These helpers send the reports to the journal and to the log
# files the packages already write, and read nothing from a mailer.
#
# Every path under /etc and /var goes through av_path, so a test can point
# AV_ROOT at a scratch tree. AV_ROOT is empty by default (the real system).

# av_path /abs/path -> "${AV_ROOT}/abs/path"
av_path() { printf '%s%s' "${AV_ROOT:-}" "$1"; }

av_have_mailer() { have mail || have sendmail; }

# av_get_var FILE VAR -> the value of the last uncommented VAR= line, unquoted.
# Prints nothing (and returns 1) when there is none.
av_get_var() {
    local file="$1" var="$2" line
    [ -f "$file" ] || return 1
    line="$(grep -E "^[[:space:]]*${var}=" "$file" | tail -n 1)" || true
    [ -n "$line" ] || return 1
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s\n' "$line"
}

# av_set_var FILE VAR VALUE   (VALUE is the text after '=', quotes included)
# Edits only the one variable line: rewrites it, or appends it when the file has
# no uncommented assignment. Keeps FILE.linux-av.bak the first time and edits
# nothing when that copy cannot be made. Leaves a symlink alone (sed -i would
# replace it with a regular file) and a file the edit would leave unparsable (a
# value spread over lines). No-op when the effective line is already right.
# Logs what changed.
av_set_var() {
    local file="$1" var="$2" want="$3" line cur new
    line="${var}=${want}"
    if [ ! -f "$file" ]; then
        log_info "$file is not present; $var left alone"
        return 0
    fi
    if [ -L "$file" ]; then
        log_warn "$file is a symlink; $var left alone (set $line in its target by hand)"
        return 1
    fi
    cur="$(grep -E "^[[:space:]]*${var}=" "$file" | tail -n 1)" || true
    [ "$cur" = "$line" ] && return 0
    if [ -n "$cur" ]; then
        new="$(sed "s|^[[:space:]]*${var}=.*|${line}|" "$file")"
    else
        new="$(cat "$file")"$'\n'"$line"
    fi
    if ! "${BASH:-bash}" -n <<<"$new" 2>/dev/null; then
        log_warn "$file: $line would not parse there (a value spread over lines?); $var left alone"
        return 1
    fi
    [ -e "$file.linux-av.bak" ] || cp -p "$file" "$file.linux-av.bak" \
        || { log_warn "$file: could not keep $file.linux-av.bak; $var left alone"; return 1; }
    if [ -n "$cur" ]; then
        sed -i "s|^[[:space:]]*${var}=.*|${line}|" "$file"
        log_info "$file: set $line (was: $cur); original kept in $file.linux-av.bak"
    else
        [ -z "$(tail -c 1 "$file")" ] || printf '\n' >> "$file"
        printf '%s\n' "$line" >> "$file"
        log_info "$file: added $line; original kept in $file.linux-av.bak"
    fi
}

# Step 2 — reports go to the journal or a log, never to a mailer that is not there.
#   chkrootkit-daily: MAILTO empty -> output on stdout -> the journal
#                     (read from /usr/sbin/chkrootkit-daily: `if [ -n "$MAILTO" ]`
#                     mails, `else cat "$FILE"`).
#   dailyaidecheck:   MAILTO empty does NOT work, the script defaults it to root
#                     (`MAILTO="${MAILTO:-root}"`). send_mail() evals $MAILCMD when
#                     it is non-empty, so MAILCMD=":" makes the mail a no-op; the
#                     report stays in /var/log/aide/.
#   rkhunter cron:    REPORT_EMAIL empty -> /etc/cron.daily/rkhunter does not call
#                     sendmail; rkhunter --appendlog still writes /var/log/rkhunter.log.
# Only when neither `mail` nor `sendmail` is on PATH; a machine with a mailer
# keeps its config. AV_QUIET_REPORTS=0 turns this off.
av_quiet_reports() {
    if [ "${AV_QUIET_REPORTS:-1}" = 0 ]; then
        log_info "AV_QUIET_REPORTS=0 — scanner mail settings left as they are"
        return 0
    fi
    if av_have_mailer; then
        log_info "a mailer is on PATH — scanner mail settings kept"
        return 0
    fi
    log_info "no mail or sendmail on PATH — pointing scanner reports at the journal and logs"
    av_set_var "$(av_path /etc/chkrootkit/chkrootkit.conf)" MAILTO '""'
    local aide_cfg cur
    aide_cfg="$(av_path /etc/default/aide)"
    cur="$(av_get_var "$aide_cfg" MAILCMD || true)"
    if [ -n "$cur" ] && [ "$cur" != ":" ]; then
        log_info "$aide_cfg already sets MAILCMD to a command of yours — kept"
    else
        av_set_var "$aide_cfg" MAILCMD '":"'
    fi
    av_set_var "$(av_path /etc/default/rkhunter)" REPORT_EMAIL '""'
}

# Step 3 — rkhunter runs nightly on Debian/Ubuntu. Its daily job is
# /etc/cron.daily/rkhunter (the package ships no systemd timer), which runs only
# when CRON_DAILY_RUN starts with y/t; CRON_DB_UPDATE does the same for the weekly
# database update. AV_RKHUNTER_DAILY=0 turns this off.
av_rkhunter_daily() {
    [ "$AV_FAMILY" = debian ] || return 0
    if [ "${AV_RKHUNTER_DAILY:-1}" = 0 ]; then
        log_info "AV_RKHUNTER_DAILY=0 — rkhunter's daily run left as it is"
        return 0
    fi
    local cfg; cfg="$(av_path /etc/default/rkhunter)"
    av_set_var "$cfg" CRON_DAILY_RUN '"true"'
    av_set_var "$cfg" CRON_DB_UPDATE '"true"'
    if have systemctl && ! systemctl cat cron.service >/dev/null 2>&1 \
                      && ! systemctl cat crond.service >/dev/null 2>&1; then
        log_warn "no cron service found — rkhunter's daily job is /etc/cron.daily/rkhunter and will not run without one (apt install cron)"
    fi
    if have rkhunter && [ ! -e "$(av_path /var/lib/rkhunter/db/rkhunter.dat)" ]; then
        log_info "no rkhunter property database yet — running: rkhunter --propupd"
        rkhunter --propupd >/dev/null 2>&1 \
            || log_warn "rkhunter --propupd failed; run it by hand"
    fi
}

# Step 1 — the AIDE baseline in its own systemd unit, so it does not die with the
# caller's terminal (raspberrypi5: aideinit killed with the terminal, no database,
# dailyaidecheck failed). The same command av-setup always ran.
av_aide_baseline() {
    local unit="${AV_AIDE_INIT_UNIT:-linux-av-aide-init}"
    local limit="${AV_AIDE_INIT_TIMEOUT:-4h}"
    local -a cmd
    if [ "$AV_FAMILY" = debian ]; then
        cmd=(aideinit -y -f)
    else
        local dir; dir="$(av_path /var/lib/aide)"
        # shellcheck disable=SC2016
        cmd=(sh -c 'aide --init && mv -f "$1" "$2"' sh "$dir/aide.db.new.gz" "$dir/aide.db.gz")
    fi
    if systemctl is-active --quiet "$unit.service" 2>/dev/null; then
        log_info "the AIDE baseline is already building ($unit.service) — not starting a second"
    elif have systemd-run; then
        log_info "building the AIDE baseline in its own unit, detached from this terminal ..."
        if systemd-run --unit="$unit" --property=RuntimeMaxSec="$limit" --collect "${cmd[@]}"; then
            log_info "baseline started as $unit.service (limit $limit)"
        else
            log_warn "could not start $unit.service; build the baseline by hand: ${cmd[*]}"
            return 0
        fi
    else
        log_warn "systemd-run not found — building the baseline in this terminal (do not close it)"
        "${cmd[@]}" || log_warn "${cmd[0]} failed"
        return 0
    fi
    log_info "watch it:  systemctl status $unit   |   journalctl -u $unit -f"
    log_info "the periodic AIDE check is enabled now but reports \"no database\" until the baseline finishes"
}

# Step 4 — chkrootkit's expected output. av-setup does not run chkrootkit, so it
# cannot know a clean run happened by itself; it reads the nightly run's own
# log.today instead, and adopts it as log.expected only when that file exists,
# is not empty, and has no INFECTED, Vulnerable, WARNING or Warning line (otherwise it lists them and prints the cp -a command for after reading), and log.expected does
# not exist yet. Run by `av-setup chkrootkit-baseline`, and at the end of `enable`.
# Returns 1 when log.today holds a finding (nothing is copied).
av_chkrootkit_baseline() {
    local dir today expected
    dir="$(av_path /var/log/chkrootkit)"
    today="$dir/log.today"; expected="$dir/log.expected"
    if [ -e "$expected" ]; then
        log_info "chkrootkit baseline present ($expected)"
        return 0
    fi
    if [ ! -s "$today" ]; then
        log_info "chkrootkit has not produced $today yet; after its first nightly run: av-setup chkrootkit-baseline"
        return 0
    fi
    # chkrootkit 0.58b prints most rootkit findings as "WARNING: Possible ... installed"
    # (its _warn/_report), a few as "Warning: ..."; neither says INFECTED.
    if grep -Eq 'INFECTED|Vulnerable|WARNING|Warning' "$today"; then
        log_warn "$today holds an INFECTED, Vulnerable or WARNING line — not adopted as the baseline:"
        grep -nE 'INFECTED|Vulnerable|WARNING|Warning' "$today" | head -n 20 >&2
        log_warn "read it; if every line is expected, adopt it by hand: cp -a $today $expected"
        return 1
    fi
    cp -a "$today" "$expected"
    log_info "chkrootkit baseline adopted: $today -> $expected"
}

# Step 5 — status lines.
av_report_status() {
    local unit="${AV_AIDE_INIT_UNIT:-linux-av-aide-init}" db="" f v
    echo
    printf '== reports and baselines ==\n'
    for f in "$(av_path /var/lib/aide)/aide.db" "$(av_path /var/lib/aide)/aide.db.gz"; do
        [ -s "$f" ] && { db="$f"; break; }
    done
    if have systemctl && systemctl is-active --quiet "$unit.service" 2>/dev/null; then
        printf '  aide baseline:       building (systemctl status %s)\n' "$unit"
    elif [ -n "$db" ]; then
        printf '  aide baseline:       present (%s)\n' "$db"
    else
        printf '  aide baseline:       absent (the periodic check reports "no database")\n'
    fi
    v="$(av_get_var "$(av_path /etc/default/aide)" MAILCMD || true)"
    if [ "$v" = ":" ]; then
        printf '  aide report:         %s (mail off)\n' "$(av_path /var/log/aide)/"
    else
        printf '  aide report:         %s (mail per /etc/default/aide)\n' "$(av_path /var/log/aide)/"
    fi
    v="$(av_get_var "$(av_path /etc/chkrootkit/chkrootkit.conf)" MAILTO || true)"
    if [ -f "$(av_path /etc/chkrootkit/chkrootkit.conf)" ] && [ -z "$v" ]; then
        printf '  chkrootkit report:   journal (chkrootkit.service) and %s (mail off)\n' "$(av_path /var/log/chkrootkit/log.today)"
    else
        printf '  chkrootkit report:   %s (mail to "%s")\n' "$(av_path /var/log/chkrootkit/log.today)" "$v"
    fi
    if [ -e "$(av_path /var/log/chkrootkit/log.expected)" ]; then
        printf '  chkrootkit baseline: present (log.expected)\n'
    else
        printf '  chkrootkit baseline: absent (after its first clean nightly run: av-setup chkrootkit-baseline)\n'
    fi
    v="$(av_get_var "$(av_path /etc/default/rkhunter)" REPORT_EMAIL || true)"
    if [ -f "$(av_path /etc/default/rkhunter)" ] && [ -z "$v" ]; then
        printf '  rkhunter report:     %s (mail off)\n' "$(av_path /var/log/rkhunter.log)"
    else
        printf '  rkhunter report:     %s (mail to "%s")\n' "$(av_path /var/log/rkhunter.log)" "$v"
    fi
    v="$(av_get_var "$(av_path /etc/default/rkhunter)" CRON_DAILY_RUN || true)"
    case "$v" in
        [YyTt]*) printf '  rkhunter daily run:  on\n' ;;
        *)       printf '  rkhunter daily run:  off\n' ;;
    esac
    if [ -e "$(av_path /var/lib/rkhunter/db/rkhunter.dat)" ]; then
        printf '  rkhunter database:   present\n'
    else
        printf '  rkhunter database:   absent (rkhunter --propupd)\n'
    fi
}
