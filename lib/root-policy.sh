#!/usr/bin/env bash
# Sourced only after common.sh. Plan and back up every managed write before
# replacing anything. Production has no test root or activation switch.
av_install_power_policy() { av_power_policy install; }
av_verify_power_policy() { av_power_policy verify; }
# One plan/render/readback path. Verification never creates staging, backups,
# directories or log files and never asks systemd to change anything.
av_power_policy() (
    set -euo pipefail
    local action=${1:?} base=
    if [ "$EUID" = 0 ]; then
        [ "$AV_HOME" = /usr/local/lib/linux-av ] && [ -z "$AV_ROOT" ] || die 'power-policy requires the permanent root copy'
        /bin/sh "$AV_HOME/bin/av-guard" --power >/dev/null || exit 1
    else
        # Existing nonroot renderer tests can write only their scratch prefix.
        [ -n "$AV_ROOT" ] || die 'power-policy requires the verified root installation'
        base=$AV_ROOT
    fi
    if [ "$action" = verify ]; then
        [ ! -e "$base/etc/linux-av/power.incomplete" ] || die 'power policy installation incomplete'
    fi
    if [ "$action" = verify ] || [ "$EUID" = 0 ]; then
        local manifest=$base/etc/linux-av/power.release.sha256 hash rel extra mode count=0
        local -A seen=()
        # Manifest data comes only from the installer's independently pinned
        # private snapshot; never bless current code by recomputing its pins.
        [ -f "$manifest" ] && [ ! -L "$manifest" ] && [ "$(stat -c '%u %g %a' "$manifest")" = '0 0 644' ] || die 'missing/unsafe installed release manifest'
        while read -r hash rel extra || [ -n "$hash$rel$extra" ]; do
            [[ $hash =~ ^[0-9a-f]{64}$ ]] && [ -z "$extra" ] || die 'invalid installed release pin'
            case $rel in
                bin/av-guard|bin/av-root|bin/av-power|bin/av-scan|bin/av-setup|lib/common.sh|lib/reports.sh|lib/root-policy.sh|systemd/av-power.service|systemd/av-power.conf|systemd/av-scan.service|systemd/av-rootkit.service|systemd/av-scan.timer) ;;
                *) die "unexpected installed release input: $rel" ;;
            esac
            [ -z "${seen[$rel]:-}" ] || die "duplicate installed release pin: $rel"
            seen[$rel]=1; count=$((count+1))
            case $rel in bin/*) mode=755 ;; *) mode=644 ;; esac
            [ -f "$AV_HOME/$rel" ] && [ ! -L "$AV_HOME/$rel" ] && [ "$(stat -c '%u %g %a' "$AV_HOME/$rel")" = "0 0 $mode" ] || die "wrong release type/owner/mode: $rel"
            [ "$(sha256sum < "$AV_HOME/$rel" | cut -c1-64)" = "$hash" ] || die "installed release bytes differ: $rel"
        done < "$manifest"
        [ "$count" = 13 ] || die 'incomplete installed release manifest'
    fi
    local unit cron original file dst src mode dir t name arg i prop value shown got
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
    expected() {
        case $1 in
            guardian) cat "$AV_HOME/systemd/av-power.service" ;;
            inventory) printf '%s\n' "${units[@]}" clamav-daemon.socket | sort -u ;;
            service) cat "$AV_HOME/systemd/av-power.conf" ;;
            timer) printf '[Unit]\nConditionACPower=\n' ;;
            cron) printf '#!/bin/sh\n# linux-av mains-only cron wrapper\nexec /bin/sh /usr/local/lib/linux-av/bin/av-root av-power --cron %s\n' "$2" ;;
            upgrade) sed -E 's#^ExecStart=/usr/local/(bin/av-scan|lib/linux-av/bin/av-scan) #ExecStart=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan #' "$2" ;;
            cron-hashes)
                for name in rkhunter chkrootkit aide aide-common; do
                    original=$base/etc/cron.daily/$name.linux-av-power-original
                    src=$original
                    # A fresh/replaced package original is still in the plan.
                    for ((i=0; i<${#targets[@]}; i++)); do
                        [ "${targets[i]}" != "$original" ] || src=${sources[i]}
                    done
                    [ ! -f "$src" ] || printf '%s  /etc/cron.daily/%s.linux-av-power-original\n' "$(sha256sum < "$src" | cut -c1-64)" "$name"
                done ;;
            *) die 'unknown policy renderer' ;;
        esac
    }
    render_plan() {
        local kind=$1 mode=$2 dest=$3 input=${4:-} staged
        if [ "$action" = verify ]; then
            sound "$dest"
            [ -f "$dest" ] && [ "$(stat -c '%u %g %a' "$dest")" = "0 0 ${mode#0}" ] || die "wrong policy type/owner/mode: $dest"
            expected "$kind" "$input" | cmp -s "$dest" - || die "policy bytes differ: $dest"
        else
            staged=$t/render.${#sources[@]}
            expected "$kind" "$input" > "$staged"
            plan "$staged" "$mode" "$dest"
        fi
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
    if [ "$EUID" = 0 ] || [ "$action" = verify ]; then
        for unit in "${units[@]}" "${timers[@]}" linux-av-power.service clamav-daemon.socket; do audit_unit "$unit"; done
    fi
    sound "$base/run"; sound "$base/etc/linux-av"; sound "$base/etc/cron.daily"
    sound "$base/etc/linux-av/power.incomplete"
    [ ! -e "$base/etc/linux-av/power.incomplete" ] || [ -f "$base/etc/linux-av/power.incomplete" ] || die 'policy incomplete marker is not regular'
    sound "$base/etc/linux-av/power.cron.sha256"
    sound "$base/etc/linux-av/power.cron.sha256.before-OC-T-0139"
    [ ! -d "$base/etc/linux-av/power.cron.sha256" ] && [ ! -d "$base/etc/linux-av/power.cron.sha256.before-OC-T-0139" ] || die 'cron digest destination is a directory'
    if [ "$action" = install ]; then
        if [ "$EUID" = 0 ]; then
            # Same lock as packaged cron, held across code + policy installation.
            sound /run/linux-av-policy.lock
            [ ! -e /run/linux-av-policy.lock ] || [ -f /run/linux-av-policy.lock ] || die 'policy lock is not regular'
            if [ ! /proc/self/fd/9 -ef /run/linux-av-policy.lock ]; then exec 9>>/run/linux-av-policy.lock; fi
            flock -n -x 9 || die 'policy/cron work in progress'
            /bin/sh "$AV_HOME/bin/av-guard" --cron-disable || exit 1
            /bin/sh "$AV_HOME/bin/av-guard" --cron-wait || exit 1
        else
            mkdir -p "$base/run"
        fi
        t=$(umask 077; mktemp -d "$base/run/linux-av-policy.XXXXXXXX")
        trap 'rm -rf --one-file-system -- "$t"' EXIT
    fi
    render_plan guardian 0644 "$units_dir/linux-av-power.service"
    render_plan inventory 0644 "$base/etc/linux-av/power.units"
    for unit in "${units[@]}"; do
        render_plan service 0644 "$units_dir/$unit.d/40-linux-av-power.conf"
    done
    for unit in "${timers[@]}"; do
        render_plan timer 0644 "$units_dir/$unit.d/40-linux-av-power.conf"
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
            # Read directly: process substitution requires /dev/fd in a chroot.
            while IFS= read -r arg || [ -n "$arg" ]; do
                [[ $arg =~ ^Exec[A-Za-z]+= ]] || continue
                case $arg in
                    ExecStart=|ExecStartPre=/usr/local/lib/linux-av/bin/av-guard) ;;
                    'ExecStart=/usr/local/bin/av-scan '*|'ExecStart=/usr/local/lib/linux-av/bin/av-scan '*|'ExecStart=/bin/sh /usr/local/lib/linux-av/bin/av-root av-scan '*) ;;
                    'ExecCondition=/bin/sh /usr/local/lib/linux-av/bin/av-root av-power '*|'ExecStopPost=/bin/sh /usr/local/lib/linux-av/bin/av-root av-power '*) ;;
                    *) die "unsupported executable in $file: $arg" ;;
                esac
            done < "$file"
            # Plan even unchanged canonical bytes so installation repairs exact
            # metadata to the same contract that read-only verification checks.
            render_plan upgrade 0644 "$file" "$file"
        done
    done
    for name in rkhunter chkrootkit aide aide-common; do
        cron=$base/etc/cron.daily/$name; original=$cron.linux-av-power-original
        sound "$cron"; sound "$original"
        [ ! -e "$cron" ] || [ -f "$cron" ] || die "cron job is not regular: $cron"
        [ ! -e "$original" ] || [ -f "$original" ] || die "cron backup is not regular: $original"
        if [ ! -f "$cron" ]; then
            [ "$action" != verify ] || [ ! -e "$original" ] || die "orphan cron original: $original"
            continue
        fi
        if [ "$action" = verify ]; then
            sound "$original"
            [ -f "$original" ] && [ "$(stat -c '%u %g %a' "$original")" = '0 0 644' ] || die "wrong cron original type/owner/mode: $original"
            ! grep -qx '# linux-av mains-only cron wrapper' "$original" || die "recursive cron original: $original"
        elif grep -qx '# linux-av cron migration disabled' "$cron"; then
            # The pinned disabler retained the raw bytes/mode and publishes the
            # working original only after disabling dispatch. Never save the
            # placeholder as a package original on a retry.
            [ -f "$base/etc/linux-av/cron-migration/$name/pending" ] && [ -f "$original" ] || die "missing pending cron original: $cron"
            cmp -s "$base/etc/linux-av/cron-migration/$name/pending" "$original" || die "pending cron original differs: $cron"
            cp "$original" "$t/original.$name"
            plan "$t/original.$name" 0644 "$original"
        elif grep -qx '# linux-av mains-only cron wrapper' "$cron"; then
            [ -f "$original" ] || die "missing original: $original"
            expected cron "${original#"$base"}" | cmp -s "$cron" - || die "malformed cron wrapper: $cron"
            cp "$original" "$t/original.$name"
            plan "$t/original.$name" 0644 "$original"
        else
            cp "$cron" "$t/original.$name"
            plan "$t/original.$name" 0644 "$original"
        fi
        render_plan cron 0755 "$cron" "${original#"$base"}"
    done
    render_plan cron-hashes 0644 "$base/etc/linux-av/power.cron.sha256"
    if [ "$action" = install ]; then
        # Backups precede every installed write. Stale .new links are unlinked,
        # never followed. Missing directories are made only after full preflight.
        for ((i=0; i<${#targets[@]}; i++)); do
            dst=${targets[i]}; src=${sources[i]}
            if [ -f "$dst" ] && ! cmp -s "$src" "$dst" && [ ! -e "$dst.before-OC-T-0139" ]; then
                cp -p -- "$dst" "$dst.before-OC-T-0139" || die "could not keep $dst"
            fi
        done
        if [ "$EUID" = 0 ]; then
            sound /etc/linux-av/power.incomplete
            [ ! -e /etc/linux-av/power.incomplete ] || [ -f /etc/linux-av/power.incomplete ] || die 'policy incomplete marker is not regular'
            install -d -o root -g root -m 0755 /etc/linux-av
            (umask 022; : > /etc/linux-av/power.incomplete)
        fi
        for dir in "${dirs[@]}"; do
            if [ "$EUID" = 0 ]; then install -d -o root -g root -m 0755 "$dir"; else mkdir -p "$dir"; fi
        done
        for ((i=0; i<${#targets[@]}; i++)); do
            dst=${targets[i]}; src=${sources[i]}; mode=${modes[i]}
            # Root cron routes remain inert until effective policy readback has
            # succeeded. The exclusive lock also holds current guarded waiters.
            if [ "$EUID" = 0 ]; then
                case $dst in "$base/etc/cron.daily/"*)
                    case $dst in *.linux-av-power-original) ;; *) continue ;; esac ;;
                esac
            fi
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
    fi
    # Reject a later drop-in that overrides or bypasses the intended commands.
    exec_fields() { sed -n "s/^$1={ path=\\(.*\\) ; argv\\[\\]=\\(.*\\) ; ignore_errors=\\([a-z]*\\) ; .*/$1 \\1 | \\2 | \\3/p"; }
    verify() {
        local shown got
        shown=$(systemctl show "$1" -p "$2") || die "cannot read back $1 $2"
        got=$(printf '%s\n' "$shown" | exec_fields "$2")
        [ "$got" = "$2 /bin/sh | /bin/sh /usr/local/lib/linux-av/bin/av-root $3 | no" ] || die "unexpected effective $2 for $1: $shown"
    }
    for unit in "${units[@]}" "${timers[@]}" linux-av-power.service clamav-daemon.socket; do
        loaded "$unit" || {
            [ ! -f "$units_dir/$unit" ] || die "installed unit not loaded: $unit"
            continue
        }
        value=$(systemctl show "$unit" -p ActiveState --value) || die "cannot inspect $unit active state"
        case $value in active|inactive|failed|activating|deactivating|reloading) ;; *) die "unsupported ActiveState for $unit: $value" ;; esac
        value=$(systemctl show "$unit" -p NeedDaemonReload --value) || die "cannot inspect $unit reload state"
        [ "$value" = no ] || die "stale loaded policy for $unit: $value"
    done
    loaded linux-av-power.service || die 'guardian not loaded'
    verify linux-av-power.service ExecStart 'av-power --watch'
    for arg in Type=simple Restart=always RestartUSec=1s RuntimeDirectory=linux-av-power RuntimeDirectoryMode=0755 RuntimeDirectoryPreserve=yes; do
        prop=${arg%%=*}
        value=$(systemctl show linux-av-power.service -p "$prop" --value) || die "cannot inspect guardian $prop"
        [ "$value" = "${arg#*=}" ] || die "unexpected effective guardian $prop: $value"
    done
    for prop in ExecStartPre ExecStartPost ExecReload ExecStop ExecStopPost ExecCondition EnvironmentFiles RootDirectory RootImage WorkingDirectory ExecSearchPath; do
        value=$(systemctl show linux-av-power.service -p "$prop" --value) || die "cannot inspect guardian $prop"
        [ -z "$value" ] || die "unsupported extra guardian command $prop: $value"
    done
    for unit in "${units[@]}"; do
        loaded "$unit" || continue
        verify "$unit" ExecCondition "av-power --check-unit $unit"
        verify "$unit" ExecStopPost "av-power --finished-unit $unit"
        for prop in Requires BindsTo After; do
            value=$(systemctl show "$unit" -p "$prop" --value) || die "cannot inspect $unit $prop"
            case " $value " in *' linux-av-power.service '*) ;; *) die "missing guardian $prop for $unit" ;; esac
        done
        for arg in KillMode=control-group KillSignal=9 TimeoutStopUSec=2s; do
            prop=${arg%%=*}
            value=$(systemctl show "$unit" -p "$prop" --value) || die "cannot inspect $unit $prop"
            [ "$value" = "${arg#*=}" ] || die "unexpected effective $prop for $unit: $value"
        done
        value=$(systemctl show "$unit" -p Conditions --value) || die "cannot inspect $unit Conditions"
        [[ $value != *ConditionACPower* ]] || die "AC condition bypasses queue for $unit"
    done
    for unit in "${timers[@]}"; do
        loaded "$unit" || continue
        value=$(systemctl show "$unit" -p Conditions --value) || die "cannot inspect $unit Conditions"
        [[ $value != *ConditionACPower* ]] || die "AC condition bypasses service gate for $unit"
    done
    for name in "$AV_TIMER_NAME" "$AV_ROOTKIT_TIMER_NAME"; do
        if loaded "$name.service"; then
            for prop in ExecStartPost ExecReload ExecStop EnvironmentFiles RootDirectory RootImage WorkingDirectory ExecSearchPath; do
                value=$(systemctl show "$name.service" -p "$prop" --value) || die "cannot inspect $name $prop"
                [ -z "$value" ] || die "unsupported effective $prop for $name: $value"
            done
            shown=$(systemctl show "$name.service" -p ExecStartPre) || die "cannot inspect $name ExecStartPre"
            value=$(systemctl show "$name.service" -p ExecStartPre --value) || die "cannot inspect $name ExecStartPre"
            if [ -n "$value" ]; then
                got=$(printf '%s\n' "$shown" | exec_fields ExecStartPre)
                [ "$got" = 'ExecStartPre /usr/local/lib/linux-av/bin/av-guard | /usr/local/lib/linux-av/bin/av-guard | no' ] || die "unsupported effective ExecStartPre for $name: $shown"
            fi
            shown=$(systemctl show "$name.service" -p ExecStart) || die "cannot read back $name"
            got=$(printf '%s\n' "$shown" | exec_fields ExecStart)
            case $got in
                'ExecStart /bin/sh | /bin/sh /usr/local/lib/linux-av/bin/av-root av-scan '*" | no") ;;
                *) die "unexpected effective ExecStart for $name: $shown" ;;
            esac
        fi
    done
    if [ "$action" = verify ]; then
        printf '%s\n' 'linux-av: installed power policy verified'
    else
        # Only now is policy ready. Publish complete guarded routes while still
        # holding the lock and incomplete gate, then durably retire pending state.
        if [ "$EUID" = 0 ]; then
            for name in rkhunter chkrootkit aide aide-common; do
                dst=$base/etc/cron.daily/$name
                [ -f "$dst" ] || continue
                src=$t/activate.$name
                expected cron "/etc/cron.daily/$name.linux-av-power-original" > "$src"
                rm -f -- "$dst.new"
                install -o root -g root -m 0755 "$src" "$dst.new"
                sync -f "$dst.new"
                mv -fT -- "$dst.new" "$dst"
                sync -f "${dst%/*}"
                file=$base/etc/linux-av/cron-migration/$name/pending
                rm -f -- "$file"
                # Wrapper inodes are needed only across this drain. Raw package
                # inode records and independent archives remain preserved.
                rm -f -- "${file%/*}"/open.wrapper.*
                [ ! -d "${file%/*}" ] || sync -f "${file%/*}"
            done
        fi
        rm -f /etc/linux-av/power.incomplete
        [ "$EUID" != 0 ] || sync -f /etc/linux-av
        log_info 'power policy installed; no unit started, stopped, enabled or restarted'
    fi
)
