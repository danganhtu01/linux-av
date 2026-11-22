#!/usr/bin/env bash
# Sourced only after common.sh. Plan and back up every managed write before
# replacing anything. Production has no test root or activation switch.
av_install_power_policy() (
    set -euo pipefail
    local base=
    if [ "$EUID" = 0 ]; then
        [ "$AV_HOME" = /usr/local/lib/linux-av ] && [ -z "$AV_ROOT" ] || die 'power-policy requires the permanent root copy'
        /bin/sh "$AV_HOME/bin/av-guard" --power >/dev/null || exit 1
    else
        # Existing nonroot renderer tests can write only their scratch prefix.
        [ -n "$AV_ROOT" ] || die 'power-policy requires the verified root installation'
        base=$AV_ROOT
    fi
    local unit cron original file rel dst src mode dir t name arg
    local units_dir=$base/etc/systemd/system
    local -a units=(clamav-daemon.service clamav-clamonacc.service
        chkrootkit.service rkhunter.service aidecheck.service dailyaidecheck.service
        "$AV_AIDE_INIT_UNIT.service" "$AV_TIMER_NAME.service" "$AV_ROOTKIT_TIMER_NAME.service")
    local -a timers=(chkrootkit.timer rkhunter.timer aidecheck.timer dailyaidecheck.timer
        "$AV_TIMER_NAME.timer" "$AV_ROOTKIT_TIMER_NAME.timer")
    local -a sources=() targets=() modes=() dirs=()
    # Walk ancestors as well as the leaf, even for paths not yet created.
    sound() {
        local path=$1 cur=/ part rest=${1#/} perm
        while :; do
            [ ! -L "$cur" ] || die "refusing symlink $cur"
            if [ -e "$cur" ]; then
                perm=$(stat -c '%u %a' "$cur")
                if [ "$EUID" = 0 ]; then
                    [ "${perm%% *}" = 0 ] && (( (8#${perm#* } & 8#022) == 0 )) || die "unsafe owner/mode: $cur"
                fi
                [ -d "$cur" ] || [ -f "$cur" ] || die "not a regular file/directory: $cur"
                [ "$cur" = "$path" ] || [ -d "$cur" ] || die "not a directory: $cur"
            fi
            [ -n "$rest" ] || break
            part=${rest%%/*}; cur=${cur%/}/$part
            case $rest in */*) rest=${rest#*/} ;; *) rest= ;; esac
        done
    }
    # systemd can also load vendor fragments, /run drop-ins and environment
    # files. Audit the effective paths before writing; root-owned OS aliases
    # (e.g. /lib -> /usr/lib) are allowed only with a sound resolved target.
    sound_system() {
        local rest=${1#/} cur=/ resolved owner
        [[ $1 = /* && $1 != *\\* ]] || die "unsupported systemd path: $1"
        while :; do
            if [ -L "$cur" ]; then
                owner=$(stat -c %u "$cur")
                [ "$owner" = 0 ] || die "foreign system link: $cur"
            fi
            resolved=$(readlink -m -- "$cur")
            sound "$resolved"
            [ -n "$rest" ] || break
            cur=${cur%/}/${rest%%/*}
            case $rest in */*) rest=${rest#*/} ;; *) rest= ;; esac
        done
    }
    loaded() {
        local state
        state=$(systemctl show "$1" -p LoadState --value) || [ "$state" = not-found ] || die "cannot inspect $1"
        case $state in loaded) return 0 ;; not-found) return 1 ;; *) die "unsupported LoadState for $1: $state" ;; esac
    }
    audit_unit() {
        local prop values path
        loaded "$1" || return 0
        for prop in FragmentPath DropInPaths EnvironmentFiles; do
            values=$(systemctl show "$1" -p "$prop" --value) || die "cannot inspect $1 $prop"
            for path in $values; do
                case $path in '(ignore_errors=yes)'|'(ignore_errors=no)') continue ;; esac
                sound_system "$path"
            done
        done
    }
    plan() {
        sound "$3"
        [ ! -d "$3" ] || die "destination is a directory: $3"
        sound "$3.before-OC-T-0139"
        [ ! -d "$3.before-OC-T-0139" ] || die "backup is a directory: $3"
        sources+=("$1"); modes+=("$2"); targets+=("$3")
        dirs+=("${3%/*}")
    }
    for unit in "${units[@]}" "${timers[@]}"; do
        [[ $unit =~ ^[a-zA-Z0-9_:@.-]+\.(service|timer)$ ]] || die "invalid policy unit: $unit"
        sound "$units_dir/$unit"; sound "$units_dir/$unit.d"
        if [ -d "$units_dir/$unit.d" ]; then
            for file in "$units_dir/$unit.d"/* "$units_dir/$unit.d"/.[!.]* "$units_dir/$unit.d"/..?*; do
                [ -e "$file" ] || [ -L "$file" ] || continue
                sound "$file"
            done
        fi
    done
    if [ "$EUID" = 0 ]; then
        for unit in "${units[@]}" "${timers[@]}" linux-av-power.service clamav-daemon.socket; do audit_unit "$unit"; done
    fi
    sound "$base/run"; sound "$base/etc/linux-av"; sound "$base/etc/cron.daily"
    [ "$EUID" = 0 ] || mkdir -p "$base/run"
    t=$(umask 077; mktemp -d "$base/run/linux-av-policy.XXXXXXXX")
    trap 'rm -rf --one-file-system -- "$t"' EXIT
    cp "$AV_HOME/systemd/av-power.service" "$t/guardian"
    plan "$t/guardian" 0644 "$units_dir/linux-av-power.service"
    printf '%s\n' "${units[@]}" clamav-daemon.socket | sort -u > "$t/inventory"
    plan "$t/inventory" 0644 "$base/etc/linux-av/power.units"
    for unit in "${units[@]}"; do
        plan "$AV_HOME/systemd/av-power.conf" 0644 "$units_dir/$unit.d/40-linux-av-power.conf"
    done
    printf '[Unit]\nConditionACPower=\n' > "$t/timer"
    for unit in "${timers[@]}"; do
        plan "$t/timer" 0644 "$units_dir/$unit.d/40-linux-av-power.conf"
    done
    # Upgrade existing linux-av commands, including root-owned.conf overrides.
    # Preserve every other byte: CPU/memory/time limits, guards, timer state.
    # Unknown commands / environment-file inputs require a separate host review.
    for name in "$AV_TIMER_NAME" "$AV_ROOTKIT_TIMER_NAME"; do
        for file in "$units_dir/$name.service" "$units_dir/$name.service.d"/*.conf; do
            [ -f "$file" ] || continue
            if grep -Eq '^[[:space:]]*(EnvironmentFile|RootDirectory|RootImage|WorkingDirectory|ExecSearchPath)=' "$file"; then
                die "unsupported root input in $file; review before upgrading"
            fi
            [ "${file##*/}" != 40-linux-av-power.conf ] || continue
            while IFS= read -r arg; do
                case $arg in
                    ExecStart=|ExecStartPre=/usr/local/lib/linux-av/bin/av-guard) ;;
                    'ExecStart=/usr/local/bin/av-scan '*|'ExecStart=/usr/local/lib/linux-av/bin/av-scan '*|'ExecStart=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan '*) ;;
                    'ExecCondition=/bin/sh /usr/local/lib/linux-av/bin/av-root av-power '*|'ExecStopPost=/bin/sh /usr/local/lib/linux-av/bin/av-root av-power '*) ;;
                    *) die "unsupported executable in $file: $arg" ;;
                esac
            done < <(grep -E '^Exec[A-Za-z]+=' "$file" || true)
            rel="upgrade.${#sources[@]}"
            sed -E 's|^ExecStart=/usr/local/(bin/av-scan|lib/linux-av/bin/av-scan) |ExecStart=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan |' "$file" > "$t/$rel"
            cmp -s "$file" "$t/$rel" || plan "$t/$rel" 0644 "$file"
        done
    done
    for name in rkhunter chkrootkit aide aide-common; do
        cron=$base/etc/cron.daily/$name; original=$cron.linux-av-power-original
        sound "$cron"; sound "$original"
        [ ! -e "$cron" ] || [ -f "$cron" ] || die "cron job is not regular: $cron"
        [ ! -e "$original" ] || [ -f "$original" ] || die "cron backup is not regular: $original"
        [ -f "$cron" ] || continue
        if grep -qx '# linux-av mains-only cron wrapper' "$cron"; then
            [ -f "$original" ] || die "missing original: $original"
        else
            cp "$cron" "$t/original.$name"
            plan "$t/original.$name" 0644 "$original"
        fi
        printf '#!/bin/sh\n# linux-av mains-only cron wrapper\nexec /bin/sh /usr/local/lib/linux-av/bin/av-root av-power --cron %s\n' "$original" > "$t/cron.$name"
        plan "$t/cron.$name" 0755 "$cron"
    done
    # Backups precede every installed write. Stale .new links are unlinked,
    # never followed. Missing directories are made only after full preflight.
    for ((i=0; i<${#targets[@]}; i++)); do
        dst=${targets[i]}; src=${sources[i]}
        if [ -f "$dst" ] && ! cmp -s "$src" "$dst" && [ ! -e "$dst.before-OC-T-0139" ]; then
            cp -p -- "$dst" "$dst.before-OC-T-0139" || die "could not keep $dst"
        fi
    done
    for dir in "${dirs[@]}"; do
        if [ "$EUID" = 0 ]; then install -d -o root -g root -m 0755 "$dir"; else mkdir -p "$dir"; fi
    done
    for ((i=0; i<${#targets[@]}; i++)); do
        dst=${targets[i]}; src=${sources[i]}; mode=${modes[i]}
        if cmp -s "$src" "$dst" && [ "$(stat -c '%u %g %a' "$dst")" = "0 0 ${mode#0}" ]; then continue; fi
        rm -f -- "$dst.new"
        if [ "$EUID" = 0 ]; then
            install -o root -g root -m "$mode" "$src" "$dst.new"
        else
            cp "$src" "$dst.new"; chmod "$mode" "$dst.new"
        fi
        mv -f -- "$dst.new" "$dst"
    done
    [ "$EUID" != 0 ] || /bin/sh "$AV_HOME/bin/av-guard" --power
    systemctl daemon-reload
    [ "$EUID" = 0 ] || return 0
    # Reject a later drop-in that overrides or bypasses the intended commands.
    exec_fields() { sed -n "s/^$1={ path=\\(.*\\) ; argv\\[\\]=\\(.*\\) ; ignore_errors=\\([a-z]*\\) ; .*/$1 \\1 | \\2 | \\3/p"; }
    verify() {
        local shown got
        shown=$(systemctl show "$1" -p "$2") || die "cannot read back $1 $2"
        got=$(printf '%s\n' "$shown" | exec_fields "$2")
        [ "$got" = "$2 /bin/sh | /bin/sh /usr/local/lib/linux-av/bin/av-root $3 | no" ] || die "unexpected effective $2 for $1: $shown"
    }
    verify linux-av-power.service ExecStart 'av-power --watch'
    for prop in ExecStartPre ExecStartPost ExecReload ExecStop ExecStopPost ExecCondition; do
        value=$(systemctl show linux-av-power.service -p "$prop" --value) || die "cannot inspect guardian $prop"
        [ -z "$value" ] || die "unsupported extra guardian command $prop: $value"
    done
    for unit in "${units[@]}"; do
        loaded "$unit" || continue
        verify "$unit" ExecCondition "av-power --check-unit $unit"
        verify "$unit" ExecStopPost "av-power --finished-unit $unit"
    done
    for name in "$AV_TIMER_NAME" "$AV_ROOTKIT_TIMER_NAME"; do
        if [ -f "$units_dir/$name.service" ]; then
            shown=$(systemctl show "$name.service" -p ExecStart) || die "cannot read back $name"
            got=$(printf '%s\n' "$shown" | exec_fields ExecStart)
            case $got in
                'ExecStart /bin/sh | /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan '*" | no") ;;
                *) die "unexpected effective ExecStart for $name: $shown" ;;
            esac
        fi
    done
    log_info 'power policy installed; no unit started, stopped, enabled or restarted'
)
