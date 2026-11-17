#!/usr/bin/env bash
# tests/mutants.sh — removes each guard of the new code in a scratch copy of the
# checkout and shows the named tests/run.sh row(s) go red. A mutant that leaves its
# rows green SURVIVED, and the script exits 1.
#
#   tests/mutants.sh           run every mutant that runs as this user
#   tests/mutants.sh NAME ...  run the named mutants only
#
# Mutants named guard_* (OC-T-0037) have rows that make real owners with chown, so they run only as root; every other mutant's
# rows run av-scan, which refuses AV_ROOT as root, so they run only as another user. Run this script once as each.
#
# The checkout itself is never changed: each mutant is applied to a copy under
# $TMPDIR. The copies are left in place (AV_TEST_KEEP=1 is passed to the rows);
# the scratch directory is $TMPDIR/linux-av-mutants.XXXXXX.

set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/linux-av-mutants.XXXXXX")" || exit 2

# NAME~FILE~SED-EXPRESSION~ROWS that must go red (space-separated)
# shellcheck disable=SC2016
MUTANTS=(
# OC-T-0080 (FAULT-0017): odd names batch by bytes. odd_batch_d158e91_limits restores that commit's limits (a name count of 128
# and 8192, now in bytes); odd_batch_count_limit restores the name count alone; each of the others moves a batch by a name or more.
'odd_batch_unbounded~bin/av-scan~s/\[ "$bytes" -lt "$limit" \] || break/:/~scan_changed_odd_batches'
'odd_batch_d158e91_limits~bin/av-scan~s/\[ "$bytes" -lt "$limit" \] || break/[ "$bytes" -lt 8192 ] \&\& [ "${#targets[@]}" -lt 128 ] || break/~scan_changed_odd_batches'
'odd_batch_count_limit~bin/av-scan~s/\[ "$bytes" -lt "$limit" \] || break/[ "$bytes" -lt "$limit" ] \&\& [ "${#targets[@]}" -lt 128 ] || break/~scan_changed_odd_batches'
'odd_batch_overhead_dropped~bin/av-scan~s/REPLY=$((length + 9))/REPLY=$length/~scan_changed_odd_batches'
'odd_batch_character_count~bin/av-scan~s/local LC_ALL=C length/local length/~scan_changed_odd_batches'
'odd_batch_helper_unserialized~bin/av-scan~s/declare -f run_clamscan_batches run_clamscan_one scan_argv_bytes/declare -f run_clamscan_batches run_clamscan_one/~scan_changed_odd_batches'
# OC-T-0111: the bound is the smaller of 1 MiB and half of getconf's ARG_MAX. Each mutant removes one part of that: the lowering, its
# halving, the 1 MiB cap, the test that getconf gave a number, the silenced stderr, the name asked for, and the size of the fallback.
'odd_batch_arg_max_ignored~bin/av-scan~s/then limit=\$((arg_max \/ 2)); fi/then :; fi/~scan_changed_odd_batches_arg_max scan_changed_odd_batches_small_stack'
'odd_batch_arg_max_whole~bin/av-scan~s/then limit=\$((arg_max \/ 2)); fi/then limit=$arg_max; fi/~scan_changed_odd_batches_arg_max scan_changed_odd_batches_small_stack'
'odd_batch_arg_max_uncapped~bin/av-scan~s/ \&\& \[ \$((arg_max \/ 2)) -lt "$limit" \]; then/; then/~scan_changed_odd_batches_arg_max'
'odd_batch_arg_max_unchecked~bin/av-scan~s/\[\[ \$arg_max =. \^\[1-9\]\[0-9\]\*\$ \]\] \&\& //~scan_changed_odd_batches_arg_max'
'odd_batch_arg_max_stderr~bin/av-scan~s/getconf ARG_MAX 2>\/dev\/null/getconf ARG_MAX/~scan_changed_odd_batches_arg_max'
'odd_batch_arg_max_question~bin/av-scan~s/getconf ARG_MAX/getconf PAGESIZE/~scan_changed_odd_batches_arg_max scan_changed_odd_batches_small_stack'
'odd_batch_fallback_halved~bin/av-scan~s/local limit=1048576 arg_max/local limit=524288 arg_max/~scan_changed_odd_batches scan_changed_odd_batches_arg_max'
# OC-T-0081 (FAULT-0019): the worker keeps a copy and a status for each run, and the whitelist judges each run alone. Each of the
# mutants below removes one guard of that. batch_hold_status_2 restores d158e91's early return, which no batch of status 2 passed.
'batch_hold_status_2~bin/av-scan~s/ \&\& \[ "$rc" != 2 \]; then/; then/~scan_changed_batch_vanished scan_changed_batch_worker_line'
'batch_flag_dropped~bin/av-scan~s/^        batched=1$/        batched=0/~scan_changed_batch_vanished scan_changed_batch_worker_line'
'batch_copy_whole_stream~bin/av-scan~s/copies+=("$copy_dir\/run.$((n + 1))")/copies+=("$copy")/~scan_changed_batch_vanished scan_changed_batch_worker_line'
'batch_runs_unwritten~bin/av-scan~/printf .%s\\n. "${runs\[\*\]}" > "$runs_dir\/runs"/d~scan_changed_batch_vanished scan_changed_batch_worker_line'
'batch_runner_unserialized~bin/av-scan~s/declare -f run_clamscan_batches run_clamscan_one scan_argv_bytes/declare -f run_clamscan_batches scan_argv_bytes/~scan_changed_batch_vanished scan_changed_odd_batches'
'batch_status_from_tee~bin/av-scan~s/batch_rc=${st\[0\]}/batch_rc=${st[1]}/~scan_changed_batch_vanished scan_changed_batch_worker_line scan_changed_batch_errors'
'batch_statuses_unchecked~bin/av-scan~/\[\[ ${run_rcs\[\*\]:-} =. $runs_re \]\] || bad=1/d~scan_changed_batch_errors'
'batch_status_routing~bin/av-scan~s/if \[ "${run_rcs\[n\]}" = 2 \]; then/if [ "$total_seen" = 1 ]; then/~scan_changed_batch_errors'
'batch_tee_failure_forgiven~bin/av-scan~s/\[ "${st\[1\]}" = 0 \] || code=x/:/~scan_changed_batch_errors'
'batch_stderr_dropped~bin/av-scan~s/"$@" 2>\&1 | (/"$@" | (/~scan_changed_batch_errors'
# The seat's L4: the per-run tee sits in the process group the time limit stops, and without the ignore a FOUND line still in its pipe dies with it.
'batch_tee_signals_unguarded~bin/av-scan~s/( trap .. TERM HUP INT; exec tee/( exec tee/~scan_changed_stop_keeps_found'
'batch_clean_run_judged~bin/av-scan~s/\[ "$total_seen" = 0 \] \&\& \[ "$run_count" = 0 \] || bad=1/:/~scan_changed_batch_errors scan_changed_batch_pair_errors'
'batch_failure_log_dropped~bin/av-scan~/^    if \[ -n "${odd_list:-}" \] \&\& \[ -e "$odd_list.pending" \]; then$/,/^    fi$/d~scan_pending_remove_failure scan_changed_batch_errors'
# OC-T-0112: a run the worker records as stopped (124 or above) has its own copy searched for a FOUND line, though the merged status
# is 2. Each mutant removes one guard of that: the search itself, the threshold (status 2 text is forgeable), the run's own copy
# (the whole output holds the other runs' forged text) and the test of a number (a tee that failed leaves x).
'batch_killed_found_unread~bin/av-scan~s/ || \[ "\$stopped_found" = 1 \]//~scan_changed_batch_killed_found'
'batch_stopped_threshold~bin/av-scan~s/\[ "\${stopped_rcs\[n\]}" -ge 124 \]/[ "${stopped_rcs[n]}" -ge 2 ]/~scan_changed_batch_killed_found'
'batch_stopped_whole_output~bin/av-scan~s/"\$copy_dir\/run\.\$((n + 1))"; then$/"$copy"; then/~scan_changed_batch_killed_found'
'batch_stopped_number_unchecked~bin/av-scan~s/\[\[ \${stopped_rcs\[n\]} =. \^\[0-9\]+\$ \]\] \&\& //~scan_changed_batch_errors'
# OC-T-0067 round 4: mixed errors hold stamps; PATH_MAX bounds both routes.
'batch_failure_stamp_hold_removed~bin/av-scan~/^        log_err "clamscan batch failed; stamps unchanged/{n;s/return "$rc"/:/;}~scan_changed_found_error'
'path_length_removed~bin/av-scan~s/\[ "${#1}" -lt 4096 \] \&\& return 0/return 0/~scan_changed_unscannable'
'path_length_raised~bin/av-scan~s/"${#1}" -lt 4096/"${#1}" -lt 4097/~scan_changed_unscannable'
'path_character_count~bin/av-scan~s/local LC_ALL=C label/local label/~scan_changed_unscannable'
'path_error_status_removed~bin/av-scan~/^    if \[ "$unscannable" = 1 \]; then rc=2; fi$/d~scan_changed_unscannable'
# OC-T-0067 round 3: length boundary, byte count, threat priority and CPU owner.
'file_list_length_removed~bin/av-scan~s/\&\& ${#1} -lt 1022//~scan_changed_long_names'
'file_list_length_relaxed~bin/av-scan~s/${#1} -lt 1022/${#1} -lt 1023/~scan_changed_long_names'
'file_list_character_count~bin/av-scan~/^    local LC_ALL=C$/d~scan_changed_long_names'
'batch_error_over_found~bin/av-scan~s/if \[ "$batch_rc" = 1 \]; then rc=1/if [ "$rc" -le 1 ] \&\& [ "$batch_rc" -gt "$rc" ]; then rc=$batch_rc/;s/elif \[ "$rc" = 0 \] \&\& \[ "$batch_rc" -gt 1 \]; then rc=$batch_rc/elif false; then :/~scan_changed_found_error'
'root_limits_cpu_duplicate~bin/av-scan~s@-e \x27/\^MemoryMax=/p\x27@-e \x27/^MemoryMax=/p\x27 -e \x27/^CPUQuota=/p\x27 -e \x27/^CPUWeight=/p\x27@~root_install_limits'
# OC-T-0067 round 2: each new safety property must kill its mutation.
'root_limits_missing~root-install.sh~/^put "\$t\/limits.conf"/d~root_install_limits'
'root_limits_activation~root-install.sh~s/^systemctl daemon-reload$/systemctl restart linux-av-scan.service/~root_install_limits'
'walk_race_flag~bin/av-scan~s/ -ignore_readdir_race//~scan_changed_vanishing_folder'
'walk_abort_partial~bin/av-scan~s/^                walk_failed=1$/                return 2/~scan_changed_vanishing_folder'
'walk_partial_stamp~bin/av-scan~s/^                walk_failed=1$/                walk_failed=0/~scan_changed_vanishing_folder'
'odd_batch_error_lost~bin/av-scan~s/elif \[ "$rc" = 0 \] \&\& \[ "$batch_rc" -gt 1 \]; then rc=$batch_rc; fi/else rc=$batch_rc; fi/~scan_changed_odd_error'
'scratch_component~bin/av-scan~s/(\^|\/)${REPLY}(\/|\$)/${REPLY}/~scan_scratch_components'
'scan_stamp_exit~bin/av-scan~s/\[ "$rc" -le 1 \]/true/g~scan_changed_stamps'
'scan_size_check~bin/av-scan~/^        \[\[ -z $value /d~scan_memory_invalid'
'vanished_probed_count~bin/av-scan~/\[ "$probed" = "$count" \] || bad=1/d~scan_vanished_empty_list'
'vanished_probe_condition~bin/av-scan~s@\[ "$count" -gt 0 \]; then@[ -s "$copy_dir/vanished" ]; then@~scan_vanished_empty_list'
'vanished_parent_access~bin/av-scan~/if \[ -e "$q" \]; then \[ -d "$q" \] \&\& \[ -x "$q" \] || exit 1; fi/d~scan_vanished_unsearchable scan_vanished_pair_unsearchable'
'vanished_read_reset~bin/av-scan~s/while line=; IFS= read/while IFS= read/~scan_vanished_read_failure'
'vanished_write_failure~bin/av-scan~s@>> "$copy_dir/vanished" || bad=1@>> "$copy_dir/vanished"@~scan_vanished_write_failure'
'vanished_relative~bin/av-scan~/\[\[ $p = \/\* \]\] || { bad=1; continue; }/d~scan_vanished_relative_full'
'vanished_skipped_mount~bin/av-scan~/for root in "${skipped_points\[@\]}"; do/,/done/d~scan_vanished_skipped_mount scan_vanished_pair_skipped_mount'
'vanished_dotdot~bin/av-scan~/case "$p\/" in \*\/\.\.\/\*|\*\/\.\/\*|\*\/\/\*) bad=1; continue ;; esac/d~scan_vanished_dotdot scan_vanished_noncanonical scan_vanished_pair_noncanonical'
'vanished_noncanonical~bin/av-scan~s/\*\/\.\.\/\*|\*\/\.\/\*|\*\/\/\*)/*\/..\/*)/~scan_vanished_noncanonical scan_vanished_pair_noncanonical'
'vanished_symlink_component~bin/av-scan~s/\[ ! -L "$q" \] || exit 1/:/~scan_vanished_symlink_component scan_vanished_pair_symlink_component'
'vanished_probe_limit~bin/av-scan~s/timeout -s KILL 60s "$BASH" -c/"$BASH" -c/~scan_vanished_probe_bounded'
'vanished_probe_closed~bin/av-scan~s/< "$copy_dir\/vanished")" || bad=1/< "$copy_dir\/vanished")" || :/~scan_vanished_probe_bounded'
'vanished_stderr~bin/av-scan~s/ 2>\&1 | tee/ | tee/~scan_vanished_stderr'
'vanished_infected_required~bin/av-scan~s/\[ "${detail_seen\[Infected files\]:-0}" = 1 \]/true/~scan_vanished_missing_infected'
'vanished_detail_unique~bin/av-scan~/\[ "${detail_seen\[\$kind\]:-0}" = 0 \] || bad=1/d~scan_vanished_duplicate_infected scan_vanished_duplicate_details'
'vanished_zero_total_seen~bin/av-scan~s/\[ "$total_seen" = 0 \]/[ -z "$summary" ]/~scan_vanished_zero_then_total'
'vanished_physical_copy~bin/av-scan~s/copy_dir="$resolved"/:/~scan_vanished_physical_copy'
'vanished_copy_resolution~bin/av-scan~s/resolved="$(cd -P -- "$copy_dir" \&\& pwd -P)"/resolved="$copy_dir"/~scan_vanished_copy_resolution_failure'
'vanished_kept_paths~bin/av-scan~/\[ "$matched" = 1 \] || { bad=1; continue; }/d~scan_vanished_outside_paths scan_vanished_pair_outside_paths'
'scan_function_scope~bin/av-scan~/^run_scan() {/,/^}$/ { s/^run_scan() {/run_scan() (/; s/^}$/)/; }~scan_scheduled_no_engine scan_scheduled_hook_exit'
'vanished_residual~MASTER.md~/^Residual: clamscan prints file names/d~scan_vanished_residual_documented'
'vanished_count~bin/av-scan~s/\[ "${summary:-0}" = "$run_old" \]/true/~scan_vanished_mismatch scan_changed_batch_errors scan_vanished_pair_total_higher'
'vanished_absent~bin/av-scan~s/\[ ! -L "$p" \] \&\& \[ ! -e "$p" \] || exit 1/:/~scan_vanished_reappeared scan_vanished_pair_exists scan_vanished_pair_reappeared'
'vanished_daemon~bin/av-scan~s/if \[ "$engine" = clamscan \]; then/if true; then/g~scan_vanished_clamdscan'
'vanished_cleanup~bin/av-scan~/trap .*rm -rf --.*copy_dir.* EXIT/d~scan_vanished_only'
'vanished_unknown~bin/av-scan~/Reject every unknown line/{n;s/bad=1/:/;}~scan_vanished_unknown scan_vanished_split_reason scan_vanished_found scan_vanished_pair_second_alone scan_vanished_pair_newline'
'vanished_infected~bin/av-scan~s/Infected files: 0/Infected files: [0-9]+/~scan_vanished_infected'
'vanished_second_header~bin/av-scan~s/headers=$((headers + 1))/headers=1/~scan_vanished_two_summaries'
'vanished_header_required~bin/av-scan~s/\[ "$headers" = 1 \]/true/g~scan_vanished_no_summary'
'vanished_before_summary~bin/av-scan~/\[ "$headers" = 0 \] || bad=1/d~scan_vanished_after_summary scan_vanished_pair_after_summary'
'vanished_detail_order~bin/av-scan~/elif \[\[ $line =. $detail_re \]\]; then/{n;s/.*bad=1/                    :/;}~scan_vanished_summary_order'
'vanished_total_order~bin/av-scan~/\[ "$headers" = 1 \] \&\& \[ "$total_seen" = 0 \] || bad=1/d~scan_vanished_total_order scan_vanished_duplicate_total'
'vanished_copy_exclude~bin/av-scan~/args+=("--exclude-dir=\^${escaped}.*"--exclude=/d~scan_vanished_copy_excluded'
# OC-T-0118: the vanished-file pair (a first line "PATH: No such file or directory" and, on the very next line, "WARNING: PATH: Can't
# access file"). One mutant for each of its guards. A mutant's text holds no tilde, the entry's field delimiter, and each pattern
# for the apostrophe in "Can't" is a dot. pair_first_alone and pair_line_between are the two halves of adjacency (the line after a
# first line that is not its second line leaves it alone, and the pending first line does not outlive that line); pair_open_at_end
# is a first line that no line follows; pair_same_path and pair_glob_equality are the second line's path (any path, and a path read
# as a pattern); the three after them let a pair, and no old-form warning, past the kept paths, the skipped mounts and the
# non-canonical spellings, the shared guards that vanished_kept_paths, vanished_skipped_mount and vanished_dotdot remove for both
# forms; pair_total_counted counts a pair against Total errors, vanished_count above stops comparing; pair_entry_required drops
# the rule that a run of status 2 owes an entry; the last two remove the documentation that the rows pin.
'pair_first_alone~bin/av-scan~s/; else bad=1; fi$/; fi/~scan_vanished_pair_first_alone'
'pair_line_between~bin/av-scan~s/; else bad=1; fi$/; fi/;s/^\( *\)gone=""$/\1[ -z "$entry" ] || gone=""/~scan_vanished_pair_line_between'
'pair_open_at_end~bin/av-scan~/\[ -z "$gone" \] || bad=1/d~scan_vanished_pair_first_last'
'pair_same_path~bin/av-scan~s/\[ "$line" = "WARNING: $gone: Can.t access file" \]/[[ $line = "WARNING: "*": Can"?"t access file" ]]/~scan_vanished_pair_different_paths'
'pair_glob_equality~bin/av-scan~s/\[ "$line" = "WARNING: $gone: Can.t access file" \]/[[ $line = "WARNING: "$gone": Can"?"t access file" ]]/~scan_vanished_pair_pattern_other'
'pair_kept_paths~bin/av-scan~/Do not probe a forged path outside the kept scan paths/{n;s/.*/[ "$entry" != pair ] || matched=1; [ "$matched" = 1 ] || { bad=1; continue; }/;}~scan_vanished_pair_outside_paths'
'pair_skipped_mount~bin/av-scan~s/then matched=0; break; fi/then [ "$entry" = pair ] || matched=0; break; fi/~scan_vanished_pair_skipped_mount'
'pair_noncanonical~bin/av-scan~s/) bad=1; continue ;; esac/) [ "$entry" = pair ] || { bad=1; continue; } ;; esac/~scan_vanished_pair_noncanonical'
'pair_total_counted~bin/av-scan~s/\[ "${summary:-0}" = "$run_old" \]/[ "${summary:-0}" = "$run_count" ]/~scan_vanished_pair_only scan_vanished_pair_mixed scan_vanished_pair_total_higher'
'pair_entry_required~bin/av-scan~/\[ "$run_count" -gt 0 \] || bad=1/d~scan_changed_batch_pair_errors scan_changed_batch_errors'
'pair_residual~MASTER.md~/^Residual of the pair (OC-T-0118)/d~scan_vanished_pair_documented'
'pair_readme~README.md~/A pair offsets no error: only old-form warnings count against/d~scan_vanished_pair_documented'
'scan_self_parent~bin/av-scan~s/if \[ "${fields\[1\]}" != "${fields\[0\]}" \]; then/if true; then/~scan_mount_self_parent'
'scan_reachable~bin/av-scan~s/\[ "$reachable" = 1 \] || continue/:/~scan_mount_hidden_child'
'scan_lexical_precheck~bin/av-scan~s/for stage in lexical physical/for stage in physical/~scan_path_dead_mount'
'scan_realpath_missing~bin/av-scan~s/realpath -m --/realpath -e --/~scan_path_missing_symlink'
'scan_two_pass~bin/av-scan~:a;N;$!ba;s/\(    # Check paths.*\)\(    # Exclude mounts.*    # End mount exclusions\.\n\)/\2\1/~scan_mount_dropped_parent'
'scan_fstype_match~bin/av-scan~s/\[\[ $fstype = $pattern \]\]/false/~scan_mount_cifs'
'scan_local_type_guard~bin/av-scan~s/\[\[ $fstype = $pattern \]\]/true/~scan_mount_local_types'
'scan_octal_decode~bin/av-scan~/^            mount="${mount\/\//d~scan_mount_escapes'
'scan_ere_escape~bin/av-scan~s/escaped+="\\\\"/escaped+=""/~scan_mount_escapes'
'scan_exact_anchor~bin/av-scan~s/(\/|\$)//~scan_mount_cifs'
'scan_below_path~bin/av-scan~s/\[\[ $p = \/ || $mount = "$p" || $mount = "$p\/"\* \]\]/true/~scan_mount_outside'
'scan_daemon_switch~bin/av-scan~s/\[ "${#mount_excludes\[@\]}" -gt 0 \]/false/~scan_mount_switch'
'scan_fstype_optout~bin/av-scan~s/\[ -n "$AV_EXCLUDE_FSTYPES" \]/true/;s/"${fstype_patterns\[@\]}"/"cifs"/~scan_mount_disabled'
'scan_missing_standalone~bin/av-scan~s/log_warn "clamdscan cannot enforce mount exclusions/: "clamdscan cannot enforce mount exclusions/~scan_mount_no_standalone'
'scan_mountinfo_guard~bin/av-scan~/^        \[ -r "$AV_MOUNTINFO" \]/d~scan_mount_unreadable'
'scan_timeout_wrap~bin/av-scan~s/runner=(timeout --kill-after=5m "$AV_SCAN_TIMEOUT")/runner=()/~scan_timeout'
'scan_timeout_optout~bin/av-scan~s/\[ "$AV_SCAN_TIMEOUT" != 0 \]/true/~scan_timeout_disabled'
'scan_timeout_status~bin/av-scan~/^        124) log_warn/d;/^        137) log_warn/d~scan_timeout scan_timeout_killed'
'scan_realpath~bin/av-scan~s/realpath -m --/false --/~scan_path_symlink'
'scan_drop_path~bin/av-scan~s/\[\[ $mount = \/ || $p = "$mount" || $p = "$mount\/"\* \]\]/false/~scan_path_on_mount'
'scan_empty_paths~bin/av-scan~/^    if \[ "${#paths\[@\]}" -eq 0 \]; then/,/^    fi$/d~scan_paths_all_dropped'
'scan_covered_mount~bin/av-scan~/^            \[ "${covered\[/d~scan_covered_cifs_ext4 scan_covered_autofs_ext4 scan_covered_autofs_cifs'
'scan_file_exclude~bin/av-scan~/mount_excludes+=("--exclude=\^/d~scan_mount_file'
'scan_separator_guard~bin/av-scan~/\[\[ $line = \*.* - .*\* \]\] || continue/d~scan_mount_separator'
'scan_last_line_guard~bin/av-scan~s/ || \[ -n "$line" \]//~scan_mount_last_line'
'root_mode_noop~root-install.sh~s/${2#0}/$2/~root_install_unchanged'
'root_backup_failure~root-install.sh~s/ || die "could not keep $1.before-R-3377"/ || true/~root_install_backup_failure'
'root_perl_guard~root-install.sh~/^perl -c /d~root_install_perl_guard'
'root_library_first~root-install.sh~/^put "\$here\/lib\/common.sh"/ { h; d; }; /^put "\$here\/bin\/av-scan"/ { G; }~root_install_library_first'
# OC-T-0067 round 5: the renderer runs through bash (ovh-root-run drops file modes), from the tree and not the installed copy.
'root_render_direct~root-install.sh~s/ bash "\$here\/bin\/av-scan" --render/ "$here\/bin\/av-scan" --render/~root_install_no_exec_bits'
'root_render_installed~root-install.sh~s/ bash "\$here\/bin\/av-scan" --render/ bash "$dst\/bin\/av-scan" --render/~root_install_limits root_install_no_exec_bits'
'root_install_before_render~root-install.sh~/^: > "\$t\/av.env"/i put "$here/bin/av-scan" 0755 "$dst/bin/av-scan"~root_install_render_first'
'root_install_keep_before_render~root-install.sh~/^: > "\$t\/av.env"/i keep "$dst/lib/common.sh"~root_install_render_first'
'root_render_empty_guard~root-install.sh~/rendered empty/d~root_install_render_empty'
# OC-T-0096: a keep before the empty-render guard leaves a backup; an indented closing brace lets the fixture's cut run on.
'root_keep_before_empty_guard~root-install.sh~/rendered empty/i keep "$dst/lib/common.sh"~root_install_render_empty'
'root_keep_brace_indent~root-install.sh~/^keep() {/,/^}/ s/^}$/  }/~root_install_functions_whole'
'root_put_unindented~root-install.sh~/^put() {/a echo unindented~root_install_functions_whole'
# OC-T-0083: each check of OVH's R-3377-cpu-cap.conf, each half of the mode check, the order before any keep or put, and the
# read-back after the reload. root_cap_block_removed and root_readback_removed together give bb42db6's executable lines (no guard, no read-back).
'root_cap_link_guard~root-install.sh~/^\[ ! -L "\$cap" \] || die/d~root_install_cap_link'
'root_cap_regular_guard~root-install.sh~/^\[ -f "\$cap" \] || die/d~root_install_cap_missing'
'root_cap_owner_guard~root-install.sh~/^\[ "\${perm%% \*}" = 0 \] || die/d~root_install_cap_foreign_owner'
'root_cap_group_write~root-install.sh~s/?????\[!w\]??\[!w\]?/????????[!w]?/~root_install_cap_group_writable'
'root_cap_other_write~root-install.sh~s/?????\[!w\]??\[!w\]?/?????[!w]????/~root_install_cap_other_writable'
'root_cap_quota_guard~root-install.sh~/^grep -q \x27\^CPUQuota=/d~root_install_cap_quota_missing root_install_cap_quota_empty'
'root_cap_weight_guard~root-install.sh~/^grep -q \x27\^CPUWeight=/d~root_install_cap_weight_missing root_install_cap_weight_empty'
'root_cap_quota_anchor~root-install.sh~s/grep -q \x27\^CPUQuota=/grep -q \x27CPUQuota=/~root_install_cap_quota_missing'
'root_cap_weight_anchor~root-install.sh~s/grep -q \x27\^CPUWeight=/grep -q \x27CPUWeight=/~root_install_cap_weight_missing'
'root_cap_quota_value~root-install.sh~/^grep -q \x27\^CPUQuota=/ s/\[\[:space:\]\]\*\[^\[:space:\]\]//~root_install_cap_quota_empty'
'root_cap_weight_value~root-install.sh~/^grep -q \x27\^CPUWeight=/ s/\[\[:space:\]\]\*\[^\[:space:\]\]//~root_install_cap_weight_empty'
'root_cap_after_keep~root-install.sh~/^cap=/i keep "$dst/lib/common.sh"~root_install_cap_missing'
'root_cap_after_put~root-install.sh~/^cap=/i put "$here/lib/common.sh" 0644 "$dst/lib/common.sh"~root_install_cap_missing'
'root_cap_block_removed~root-install.sh~/^cap=/,/^grep -q \x27\^CPUWeight=/d~root_install_cap_missing root_install_cap_link root_install_cap_group_writable root_install_cap_other_writable root_install_cap_foreign_owner root_install_cap_quota_missing root_install_cap_weight_missing root_install_cap_quota_empty root_install_cap_weight_empty'
'root_readback_removed~root-install.sh~/^systemctl show linux-av-scan.service -p CPUQuotaPerSecUSec/d~root_install_limits'
'root_readback_cpu_dropped~root-install.sh~s/ -p CPUQuotaPerSecUSec -p CPUWeight//~root_install_limits'
'root_readback_before_reload~root-install.sh~s/^systemctl daemon-reload$/systemctl show linux-av-scan.service -p CPUQuotaPerSecUSec -p CPUWeight -p MemoryHigh -p MemoryMax\nsystemctl daemon-reload/~root_install_limits'
'root_hash_list~bin/av-scan~1a\# a changed byte~root_install_hashes'
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
'chk_infected_guard~lib/reports.sh~s/grep -Eq .INFECTED|Vulnerable|WARNING|Warning. "$today"/grep -Eq "Vulnerable|WARNING|Warning" "$today"/~chkrootkit_baseline_infected'
'chk_vulnerable_guard~lib/reports.sh~s/grep -Eq .INFECTED|Vulnerable|WARNING|Warning. "$today"/grep -Eq "INFECTED|WARNING|Warning" "$today"/~chkrootkit_baseline_vulnerable'
'chk_warning_guard~lib/reports.sh~s/grep -Eq .INFECTED|Vulnerable|WARNING|Warning. "$today"/grep -Eq "INFECTED|Vulnerable" "$today"/~chkrootkit_baseline_warning'
'symlink_guard~lib/reports.sh~s/^    if \[ -L "$file" \]; then/    if false; then/~mail_symlink_left_alone'
'bak_proven~lib/reports.sh~s/^        || { log_warn "$file: could not keep/        || true || { log_warn "$file: could not keep/~mail_bak_failure_left_alone'
'parse_guard~lib/reports.sh~s/^    if ! "${BASH:-bash}" -n <<<"$new" 2>\/dev\/null; then/    if false; then/~mail_multiline_value_left_alone'
'nofile_guard~lib/reports.sh~s/^    if \[ ! -f "$file" \]; then/    if false; then/~mail_absent_file_not_created'
'root_prefix_refusal~lib/common.sh~s/^    die "AV_ROOT=$AV_ROOT is for tests only.*$/    :/~av_root_refused_as_root'
'root_prefix_uid~lib/common.sh~s/^    \[ "$1" -eq 0 \] || return 0$/    :/~mail_edits_applied'
'root_prefix_call~lib/common.sh~/^av_refuse_root_prefix "${EUID:-$(id -u)}"$/d~av_root_refused_as_root'
'baseline_runtime_limit~lib/reports.sh~s/--property=RuntimeMaxSec=/--property=TimeoutStartSec=/~baseline_detached_debian'
'chk_finding_status~lib/reports.sh~s/^        return 1$/        return 0/~chkrootkit_baseline_infected'
'status_baseline_building~lib/reports.sh~s/^    if have systemctl \&\& systemctl is-active --quiet "$unit.service" 2>\/dev\/null; then/    if false; then/~status_baseline_building'
'status_baseline_present~lib/reports.sh~s/^    elif \[ -n "$db" \]; then/    elif false; then/~status_baseline_present'
'status_rkhunter_on~lib/reports.sh~s/^        \[YyTt\]\*) printf .  rkhunter daily run:  on\\n. ;;/        [YyTt]*) printf "  rkhunter daily run:  off\\n" ;;/~status_reports_quiet'
'status_mail_off~lib/reports.sh~s/^    if \[ -f "$(av_path \/etc\/chkrootkit\/chkrootkit.conf)" \] \&\& \[ -z "$v" \]; then/    if false; then/~status_reports_quiet'
'status_mail_kept~lib/reports.sh~s/^    if \[ -f "$(av_path \/etc\/chkrootkit\/chkrootkit.conf)" \] \&\& \[ -z "$v" \]; then/    if true; then/~status_reports_mail_kept'
'status_chk_baseline~lib/reports.sh~s/^    if \[ -e "$(av_path \/var\/log\/chkrootkit\/log.expected)" \]; then/    if false; then/~status_chkrootkit_baseline'
'status_rkhunter_db~lib/reports.sh~s/^    if \[ -e "$(av_path \/var\/lib\/rkhunter\/db\/rkhunter.dat)" \]; then/    if false; then/~status_rkhunter_off'
'keep_check_call~bin/av-setup~s/^    enable)   check_kept_aide_baseline; do_enable ;;/    enable)   do_enable ;;/~keep_aide_baseline_db keep_aide_baseline_db_gz keep_aide_baseline_no_db_refused'
'keep_check_call_all~bin/av-setup~s/^    all)      check_kept_aide_baseline; do_install; do_enable ;;/    all)      do_install; do_enable ;;/~keep_aide_baseline_all_db keep_aide_baseline_all_no_db_refused'
'keep_check_before_install~bin/av-setup~s/check_kept_aide_baseline; do_install; do_enable/do_install; check_kept_aide_baseline; do_enable/~keep_aide_baseline_all_no_db_refused'
'keep_check_before_changes~bin/av-setup~s/^    enable)   check_kept_aide_baseline; do_enable ;;/    enable)   do_enable ;;/;s/^    elif have aide || have aide.wrapper; then$/    elif have aide || have aide.wrapper; then check_kept_aide_baseline/~keep_aide_baseline_no_db_refused'
'keep_refusal~bin/av-setup~s/^        || die "--keep-aide-baseline: no AIDE database to keep/        || : "--keep-aide-baseline: no AIDE database to keep/~keep_aide_baseline_no_db_refused keep_aide_baseline_empty_db_refused keep_aide_baseline_all_no_db_refused'
'keep_refusal_paths~bin/av-setup~s/ or $(av_path \/var\/lib\/aide)\/aide.db.gz)//~keep_aide_baseline_no_db_refused'
'keep_refusal_advice~bin/av-setup~s/; run without --keep-aide-baseline to build one"/"/~keep_aide_baseline_no_db_refused'
'keep_skips_build~bin/av-setup~s/^        if \[ -n "$KEPT_AIDE_DB" \]; then/        if false; then/~keep_aide_baseline_db keep_aide_baseline_db_gz keep_aide_baseline_all_db'
'keep_warning~bin/av-setup~s/^            log_warn "--keep-aide-baseline: keeping the existing AIDE database $KEPT_AIDE_DB; not rebuilding"/            :/~keep_aide_baseline_db keep_aide_baseline_db_gz'
'keep_still_enables_check~bin/av-setup~s/\(not rebuilding"\)$/\1; return 0/~keep_aide_baseline_db keep_aide_baseline_db_gz'
'keep_db_path_only~lib/reports.sh~s/^    for f in "$dir\/aide.db" "$dir\/aide.db.gz"; do/    for f in "$dir\/aide.db"; do/~keep_aide_baseline_db_gz'
'keep_gz_path_only~lib/reports.sh~s/^    for f in "$dir\/aide.db" "$dir\/aide.db.gz"; do/    for f in "$dir\/aide.db.gz"; do/~keep_aide_baseline_db'
'keep_empty_counts~lib/reports.sh~s/^        \[ -s "$f" \] \&\& { printf/        [ -e "$f" ] \&\& { printf/~keep_aide_baseline_empty_db_refused'
'keep_without_option~bin/av-setup~s/^    \[ "$KEEP_AIDE_BASELINE" = 1 \] || return 0/    :/~keep_aide_baseline_option_off'
'keep_init_0_wins~bin/av-setup~s/^    \[ "${AV_AIDE_INIT:-1}" = 0 \] \&\& return 0/    :/~keep_aide_baseline_aide_init_0_no_db'
'keep_init_0_warning~bin/av-setup~s/^            log_warn "--keep-aide-baseline is ignored: AV_AIDE_INIT=0 wins and skips AIDE altogether"/            :/~keep_aide_baseline_aide_init_0 keep_aide_baseline_aide_init_0_no_db'
'keep_unknown_option~bin/av-setup~s/^            \*) die "unknown option for $cmd: $opt .*$/            *) : ;;/~keep_aide_baseline_unknown_option'
'keep_parse_before_sudo~bin/av-setup~/^    enable|all) parse_enable_options "$@" ;;/d~keep_aide_baseline_sudo keep_aide_baseline_unknown_option'
'keep_option_sets_flag~bin/av-setup~s/^            --keep-aide-baseline) KEEP_AIDE_BASELINE=1 ;;/            --keep-aide-baseline) : ;;/~keep_aide_baseline_db keep_aide_baseline_db_gz keep_aide_baseline_no_db_refused'
'keep_usage_header~bin/av-setup~/^# .*--keep-aide-baseline/d~keep_aide_baseline_documented'
'keep_usage_range~bin/av-setup~s/sed -n .2,\/^$\/{\/^#\/p}. "$0"/sed -n "2,30p" "$0"/~keep_aide_baseline_documented'
'keep_readme~README.md~/--keep-aide-baseline/d~keep_aide_baseline_documented'
'keep_master~MASTER.md~/--keep-aide-baseline/d~keep_aide_baseline_documented'
# OC-T-0037: bin/av-guard and root-install-guard.sh. A name that starts guard_ marks mutants whose rows need root (real owners made
# with chown): they run only as root, and the gate runs this script a second time as root for them (see runs_here below). The first
# group removes one check of the guard; each target of the guard is dropped in turn; the rest keep the guard's reading of its own
# surroundings (PATH, base=) and its quoting. The installer's mutants follow, one for each check it makes before it writes, each part
# of what it writes, and each of the read-backs. A pattern for an apostrophe is \x27.
'guard_link_unchecked~bin/av-guard~/^    if \[ -L "\$1" \]; then fail "\$1" "is a link"; fi$/d~guard_link_leaf guard_link_parent'
'guard_missing_unchecked~bin/av-guard~/^        fail "\$1" "is missing"$/d~guard_missing_required'
'guard_optional_required~bin/av-guard~s/if \[ "\$2" = opt \]; then return 1; fi/:/~guard_config_missing_optional'
'guard_owner_unchecked~bin/av-guard~/^    if \[ "\${n_st%% \*}" != 0 \]; then fail/d~guard_foreign_owner_leaf guard_foreign_owner_parent guard_config_unsafe'
'guard_group_write_ok~bin/av-guard~s/^        ?????\[!w\]??\[!w\]?) ;;$/        ????????[!w]?) ;;/~guard_group_writable_leaf guard_group_writable_parent'
'guard_other_write_ok~bin/av-guard~s/^        ?????\[!w\]??\[!w\]?) ;;$/        ?????[!w]????) ;;/~guard_world_writable_leaf guard_world_writable_parent'
'guard_exit_zero~bin/av-guard~s/>&2; exit 1; }/>\&2; exit 0; }/~guard_link_leaf guard_foreign_owner_leaf'
'guard_ok_line~bin/av-guard~/^echo "av-guard: ok"$/d~guard_clean_passes'
'guard_top_skipped~bin/av-guard~/^    node "\${base:-\/}" req$/d~guard_base_unsafe'
'guard_walk_leaf_only~bin/av-guard~s/^        node "\$w_cur" "\$w_mode" || return 0$/        [ -n "$w_rel" ] || node "$w_cur" "$w_mode" || return 0/~guard_foreign_owner_parent guard_link_parent guard_group_writable_parent guard_world_writable_parent'
'guard_target_guard~bin/av-guard~/^walk req usr\/local\/lib\/linux-av\/bin\/av-guard$/d~guard_foreign_owner_leaf guard_group_writable_leaf'
'guard_target_scan~bin/av-guard~/^walk req usr\/local\/lib\/linux-av\/bin\/av-scan$/d~guard_foreign_owner_leaf guard_missing_required'
'guard_target_common~bin/av-guard~/^walk req usr\/local\/lib\/linux-av\/lib\/common.sh$/d~guard_foreign_owner_leaf guard_missing_required'
'guard_target_cfg_etc~bin/av-guard~/^walk opt etc\/linux-av\/av.env$/d~guard_config_unsafe'
'guard_target_cfg_root~bin/av-guard~/^walk opt root\/.config\/linux-av\/av.env$/d~guard_config_unsafe'
'guard_target_cfg_lib~bin/av-guard~/^walk opt usr\/local\/lib\/linux-av\/config\/av.env$/d~guard_config_unsafe'
'guard_target_unit_scan~bin/av-guard~/^walk req etc\/systemd\/system\/linux-av-scan.service$/d~guard_unit_file_unsafe guard_missing_required'
'guard_target_unit_rootkit~bin/av-guard~/^walk req etc\/systemd\/system\/linux-av-rootkit.service$/d~guard_unit_file_unsafe guard_missing_required'
'guard_target_dropins_scan~bin/av-guard~/^dropins etc\/systemd\/system\/linux-av-scan.service.d$/d~guard_dropin_folder_unsafe guard_dropin_file_unsafe guard_missing_required'
'guard_target_dropins_rootkit~bin/av-guard~/^dropins etc\/systemd\/system\/linux-av-rootkit.service.d$/d~guard_dropin_folder_unsafe guard_dropin_file_unsafe guard_missing_required'
'guard_target_typo~bin/av-guard~s/^walk opt etc\/linux-av\/av.env$/walk opt etc\/linux\/av.env/~guard_targets_fixed guard_config_unsafe'
'guard_cfg_etc_required~bin/av-guard~s/^walk opt etc\/linux-av\/av.env$/walk req etc\/linux-av\/av.env/~guard_config_missing_optional'
'guard_cfg_root_required~bin/av-guard~s/^walk opt root\/.config\/linux-av\/av.env$/walk req root\/.config\/linux-av\/av.env/~guard_config_missing_optional'
'guard_cfg_lib_required~bin/av-guard~s/^walk opt usr\/local\/lib\/linux-av\/config\/av.env$/walk req usr\/local\/lib\/linux-av\/config\/av.env/~guard_config_missing_optional'
'guard_dropins_walk_dropped~bin/av-guard~/^    walk req "\$1"$/d~guard_dropin_folder_unsafe'
'guard_entries_unchecked~bin/av-guard~s/then node "\$d_f" req; fi/then :; fi/~guard_dropin_file_unsafe guard_odd_names'
'guard_dotfiles_skipped~bin/av-guard~s/ "\$d_dir"\/\.\[!\.\]\*//~guard_odd_names'
'guard_dotdot_skipped~bin/av-guard~s/ "\$d_dir"\/\.\.?\*//~guard_odd_names'
'guard_dangling_skipped~bin/av-guard~s/ || \[ -L "\$d_f" \]; then/; then/~guard_odd_names'
'guard_oneline_dropped~bin/av-guard~s/"\$(oneline "\$1")"/"$1"/~guard_odd_names'
'guard_path_unset~bin/av-guard~/^PATH=\/usr\/sbin:\/usr\/bin:\/sbin:\/bin$/d~guard_path_fixed'
'guard_base_from_env~bin/av-guard~s/^base=$/base=${base-}/~guard_base_fixed'
'guard_stat_unquoted~bin/av-guard~s/n_st=\$(stat -c .%u %A. "\$1")/n_st=$(stat -c "%u %A" $1)/~guard_space_in_base'
'guard_link_test_unquoted~bin/av-guard~s/if \[ -L "\$1" \]; then fail/if [ -L $1 ]; then fail/~guard_space_in_base'
'guard_dropin_dir_unquoted~bin/av-guard~s/for d_f in "\$d_dir"\/\*/for d_f in $d_dir\/*/~guard_space_in_base'
'guard_entry_unquoted~bin/av-guard~s/then node "\$d_f" req; fi/then node $d_f req; fi/~guard_odd_names'
# The installer. guard_inst_pin_* are the chief's own request: it checks the pin in its header itself and refuses, writing nothing.
'guard_inst_root_unchecked~root-install-guard.sh~/^\[ "\$(id -u)" = 0 \] || die "not root"$/d~guard_install_not_root'
'guard_inst_host_unchecked~root-install-guard.sh~/^\[ "\$(hostname)" = OVH \]/d~guard_install_not_ovh'
'guard_inst_pin_hash_unchecked~root-install-guard.sh~/^\[ "\$(sha256sum < "\$here\/bin\/av-guard" | cut -c1-64)" = "\$pin" \]/d~guard_install_pin_mismatch'
'guard_inst_pin_count_unchecked~root-install-guard.sh~/^\[ "\$(printf .%s\\n. "\$pins" | grep -c ..)" = 1 \]/d~guard_install_pin_mismatch'
'guard_inst_pin_line_unchecked~root-install-guard.sh~/^printf .%s\\n. "\$pins" | grep -Eqx/d~guard_install_pin_mismatch'
'guard_inst_pin_path_unchecked~root-install-guard.sh~s/\(grep -Eqx .# sha256 \[0-9a-f\]{64}\) bin\/av-guard\(.\) || die/\1 [A-Za-z0-9._+\/-]+\2 || die/~guard_install_pin_mismatch'
'guard_inst_pin_file_unchecked~root-install-guard.sh~/^\[ -f "\$here\/bin\/av-guard" \] \&\& \[ ! -L "\$here\/bin\/av-guard" \]/d~guard_install_pin_mismatch'
'guard_inst_pin_comment~root-install-guard.sh~/^set -eu$/i\# sha256 stray comment~guard_install_hashes'
'guard_inst_link_unchecked~root-install-guard.sh~/^    \[ ! -L "\$2" \] || die "\$2 is a link; nothing was installed"$/d~guard_install_refuses_dropin_folders guard_install_refuses_unsafe'
'guard_inst_kind_unchecked~root-install-guard.sh~s/case \$1 in folder) \[ -d "\$2" \] ;; \*) \[ -f "\$2" \] ;; esac || die/: || die/~guard_install_refuses_dropin_folders guard_install_refuses_unsafe'
'guard_inst_owner_unchecked~root-install-guard.sh~/^    \[ "\${s%% \*}" = 0 \] || die/d~guard_install_refuses_dropin_folders guard_install_refuses_unsafe'
'guard_inst_group_write_ok~root-install-guard.sh~s/in ?????\[!w\]??\[!w\]?) ;;/in ????????[!w]?) ;;/~guard_install_refuses_dropin_folders guard_install_refuses_unsafe'
'guard_inst_other_write_ok~root-install-guard.sh~s/in ?????\[!w\]??\[!w\]?) ;;/in ?????[!w]????) ;;/~guard_install_refuses_dropin_folders guard_install_refuses_unsafe'
'guard_inst_dropin_folder_skipped~root-install-guard.sh~s/ "\$units\/linux-av-scan.service.d" "\$units\/linux-av-rootkit.service.d"; do/; do/~guard_install_refuses_dropin_folders'
'guard_inst_unit_skipped~root-install-guard.sh~s/^    sound file "\$units\/\$u"$/    :/~guard_install_refuses_unsafe'
'guard_inst_self_unreadable~root-install-guard.sh~/^\[ -f "\$0" \] \&\& \[ ! -L "\$0" \] || die/d~guard_install_pin_mismatch'
'guard_inst_backup_failure_ignored~root-install-guard.sh~s/ || die "could not keep \$1.before-OC-T-0037"/ || :/~guard_install_backup_failure'
'guard_inst_stale_new_kept~root-install-guard.sh~/^    rm -f -- "\$3.new"$/d~guard_install_stale_new'
'guard_inst_dropin_content~root-install-guard.sh~s/"ExecStartPre=\$lib\/bin\/av-guard"/"ExecStartPre=-$lib\/bin\/av-guard"/~guard_install_writes'
'guard_inst_dest_link_unchecked~root-install-guard.sh~/^    \[ ! -L "\$f" \] || die/d~guard_install_refuses_dest'
'guard_inst_dest_type_unchecked~root-install-guard.sh~/^    \[ ! -e "\$f" \] || \[ -f "\$f" \] || die/d~guard_install_refuses_dest'
'guard_inst_exec_count_unchecked~root-install-guard.sh~/^    \[ "\$(grep -c .\^ExecStart=. /d~guard_install_exec_unknown'
'guard_inst_exec_form_unchecked~root-install-guard.sh~/^    grep -qxF -e "\$old" -e "\$new"/d~guard_install_exec_unknown'
'guard_inst_rewrite_unanchored~root-install-guard.sh~s/s|\^\$old\\\$|\$new|/s|\/usr\/local\/bin\/av-scan|$lib\/bin\/av-scan|/~guard_install_writes guard_install_exec_line_only'
'guard_inst_keep_overwrites~root-install-guard.sh~/^    \[ -e "\$1.before-OC-T-0037" \] \&\& return 0$/d~guard_install_backup_first_only'
'guard_inst_keep_skipped~root-install-guard.sh~s/^    cmp -s "\$t\/\$u" "\$units\/\$u" || keep "\$units\/\$u"$/    :/~guard_install_writes guard_install_backup_first_only'
'guard_inst_unchanged_shortcut~root-install-guard.sh~s/echo "unchanged: \$3"; return 0; fi/:; fi/~guard_install_second_run'
'guard_inst_guard_mode~root-install-guard.sh~s/0755 "\$dst\/bin\/av-guard"/0775 "$dst\/bin\/av-guard"/~guard_install_writes'
'guard_inst_dropin_not_written~root-install-guard.sh~/^put "\$t\/05-guard.conf" 0644 "\$units\/linux-av-rootkit.service.d\/05-guard.conf"$/d~guard_install_writes'
'guard_inst_unit_not_written~root-install-guard.sh~s/^    put "\$t\/\$u" 0644 "\$units\/\$u"$/    :/~guard_install_writes'
'guard_inst_scratch_left~root-install-guard.sh~/^trap /d~guard_install_writes'
'guard_inst_reload_replaced~root-install-guard.sh~s/^systemctl daemon-reload$/systemctl restart linux-av-scan.service/~guard_install_no_unit_actions'
'guard_inst_readback_pre_unchecked~root-install-guard.sh~/^    \[ "\$got_pre" = /d~guard_install_readback'
'guard_inst_readback_run_unchecked~root-install-guard.sh~/^    \[ "\$got_run" = /d~guard_install_readback'
'guard_inst_readback_errors_ignored~root-install-guard.sh~/^exec_fields() /s/ | \\3\/p"/ | no\/p"/~guard_install_readback'
'guard_inst_readback_failure_ignored~root-install-guard.sh~s/ || die "systemctl show \$u failed"/ || :/~guard_install_readback'
'guard_inst_final_run_removed~root-install-guard.sh~/^"\$dst\/bin\/av-guard" || die/d~guard_install_final_guard_run'
'guard_readme~README.md~/05-guard.conf/d~guard_documented'
'guard_master~MASTER.md~/root-install-guard.sh/d~guard_documented'
)

SELECT=" $* "
KILLED=0; SURVIVED=0; SKIPPED=0
ROOT=0; [ "$(id -u)" = 0 ] && ROOT=1
# A mutant named guard_* has rows that build real owners, so it runs only as root; every other mutant's rows run av-scan, which
# refuses AV_ROOT as root, so it runs only as another user. The gate runs this script twice, once as each; a run counts the mutants
# that are not for its user as skipped and says so.
runs_here() { # mutant name
    case "$1" in guard_*) [ "$ROOT" = 1 ] ;; *) [ "$ROOT" = 0 ] ;; esac
}

# The unmutated copy must be green for each selected row first, or red means nothing.
copy_to() { # dir
    mkdir -p "$1"
    cp -r "$REPO/bin" "$REPO/lib" "$REPO/tests" "$1/"
    cp -r "$REPO/systemd" "$1/"
    [ -d "$REPO/config" ] && cp -r "$REPO/config" "$1/"
    cp "$REPO/README.md" "$REPO/MASTER.md" "$1/"
    cp "$REPO/root-install.sh" "$REPO/root-install-guard.sh" "$1/"
}
run_rows() { # dir rows...
    local dir="$1"; shift
    AV_TEST_KEEP=1 "$dir/tests/run.sh" "$@" 2>&1
}

# A selected run proves only its own rows, keeping scoped checks scoped.
BASELINE_ROWS=()
if [ "$#" -gt 0 ] || [ "$ROOT" = 1 ]; then
    for m in "${MUTANTS[@]}"; do
        IFS='~' read -r name file expr rows <<< "$m"
        runs_here "$name" || continue
        case "$SELECT" in "  ") : ;; *" $name "*) : ;; *) continue ;; esac
        read -r -a selected_rows <<< "$rows"
        BASELINE_ROWS+=("${selected_rows[@]}")
    done
    [ "${#BASELINE_ROWS[@]}" -gt 0 ] || { echo "no matching mutants"; exit 2; }
fi
copy_to "$WORK/clean"
if ! out="$(run_rows "$WORK/clean" "${BASELINE_ROWS[@]}")"; then
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
    runs_here "$name" || { SKIPPED=$((SKIPPED + 1)); continue; }
    dir="$WORK/m-$name"
    copy_to "$dir"
    sed -i "$expr" "$dir/$file"
    if [ "${file%.md}" = "$file" ] && ! bash -n "$dir/$file"; then
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
printf '%d killed, %d survived' "$KILLED" "$SURVIVED"
if [ "$SKIPPED" -gt 0 ]; then
    if [ "$ROOT" = 1 ]; then printf ', %d skipped (they run as another user)' "$SKIPPED"; else printf ', %d skipped (guard_* mutants need root)' "$SKIPPED"; fi
fi
printf '\n'
[ "$SURVIVED" -eq 0 ]
