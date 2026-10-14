#!/usr/bin/env bash
# 13_record_success_test.sh - controlled tests for 13_record_success.sh. 2026-10-15.
# MADE-UP FACTS, A REAL SCRATCH STATE FOLDER. No database, no sudo. Each case
# checks the exit code, RECORD_STATE, and what the state folder holds afterwards:
# the record (and its fingerprint and refresh time), a moved-aside record, and
# that no candidate file (state.json.new) is ever left behind.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/13_record_success.sh"
W=$(mktemp -d); trap 'chmod -R u+w "${W:?}" 2>/dev/null; rm -rf -- "${W:?}"' EXIT
FP='{"uuid": "629148b0-9f15-11ee-bf49-2569bf801689", "postmaster_start": "2026-10-14T14:03:19.386685Z", "max_aml_id": "35875286", "aml_n_tup_ins": "0", "aml_n_tup_upd": "0", "aml_n_tup_del": "0"}'
FP_NEW=${FP/2026-10-14T14:03:19.386685Z/2026-10-15T14:03:02.000001Z}
FP_LEDGER=${FP/35875286/35875290}
BUILT='2026-10-14 14:33:10.465096'
OTHER='2026-10-15 04:20:01.000000'
RUN=/tmp/fd_section4_refresh_20261014T143305Z
PINS=$(bash "$TOOL" --list-pins)
n=0 fails=0
case_() {   # EXIT STATE "name" previous(none|match|stale) [fact overrides...]
    local want=$1 want_state=$2 name=$3 prev=$4; shift 4
    n=$((n + 1))
    local d="$W/c$n" o rc=0 out
    mkdir -p "$d/state"
    case "$prev" in
        stale_locked) printf '{"last_success": {"fingerprint": %s, "refresh_time": "%s"}}\n' "$FP_LEDGER" "2026-10-13 04:14:16.332463" > "$d/state/state.json"
                      chmod 0500 "$d/state" ;;
        dirtarget) mkdir -p "$d/state/state.json/x" ;;
        match) printf '{"last_success": {"fingerprint": %s, "refresh_time": "%s"}}\n' "$FP" "$BUILT" > "$d/state/state.json" ;;
        stale) printf '{"last_success": {"fingerprint": %s, "refresh_time": "%s"}}\n' "$FP_LEDGER" "2026-10-13 04:14:16.332463" > "$d/state/state.json" ;;
    esac
    {   sed 's/^/sha:/' <<<"$PINS"
        printf 'test_state_dir|%s\nrun|%s\nrun_result|0\nrun_committed|yes\nrun_fp|%s\nbuilt|%s\nlater_attempts|\n' "$d/state" "$RUN" "$FP" "$BUILT"
        printf 'now_code|10\nnow_fp|%s\nlive_stamp|%s\ncand_code|0\nfinal_code|0\ntest_final_meta|0:600\ntest_dir_meta|0:700\n' "$FP" "$BUILT"
        if [ "$prev" = none ] || [ "$prev" = dirtarget ]; then echo "old_present|no"; else
            echo "old_present|yes"
            if [ "$prev" = match ]; then printf 'old_fp|%s\nold_built|%s\nold_code|0\n' "$FP" "$BUILT"
            else printf 'old_fp|%s\nold_built|2026-10-13 04:14:16.332463\n' "$FP_LEDGER"; fi
        fi
        for o in "$@"; do printf '%s\n' "$o"; done
    } > "$d/facts.txt"
    out=$(bash "$TOOL" --facts "$d/facts.txt" 2>&1) || rc=$?
    chmod u+w "$d/state" 2>/dev/null || true
    local got_state ok=yes detail=
    got_state=$(sed -n 's/^RECORD_STATE=//p' <<<"$out")
    [ "$rc" = "$want" ] || ok=no
    [ "$got_state" = "$want_state" ] || ok=no
    [ ! -e "$d/state/state.json.new" ] || { ok=no; detail="state.json.new left behind"; }
    if [ -n "${WANT_TEXT:-}" ]; then grep -qF -- "$WANT_TEXT" <<<"$out" || { ok=no; detail="reason missing: $WANT_TEXT"; }; fi
    case "$want_state" in
        written)
            python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["last_success"]; assert d["fingerprint"]==json.loads(sys.argv[2]) and d["refresh_time"]==sys.argv[3]' \
                "$d/state/state.json" "$(awk -F'|' '$1=="run_fp"{v=substr($0,8)} END{print v}' "$d/facts.txt")" \
                "$(awk -F'|' '$1=="built"{v=$2} END{print v}' "$d/facts.txt")" 2>/dev/null || { ok=no; detail="record content wrong"; }
            [ "$(stat -c '%a' "$d/state/state.json" 2>/dev/null || stat -f '%Lp' "$d/state/state.json")" = 600 ] || { ok=no; detail="record mode"; } ;;
        invalidated)
            [ ! -e "$d/state/state.json" ] && ls "$d/state"/state.json.invalid-* > /dev/null 2>&1 || { ok=no; detail="not moved aside"; } ;;
        kept)
            grep -q "$BUILT" "$d/state/state.json" 2>/dev/null || { ok=no; detail="record not kept"; } ;;
        unknown)
            [ -e "$d/state/state.json" ] || { ok=no; detail="the record vanished"; } ;;
        absent|unchanged)
            if [ "$prev" = none ]; then [ ! -e "$d/state/state.json" ] || { ok=no; detail="a record appeared"; }
            else [ -e "$d/state/state.json" ] || { ok=no; detail="the record vanished"; }; fi ;;
    esac
    if [ "$ok" = yes ]; then printf 'PASS  %2s %-12s %s\n' "$rc" "$got_state" "$name"
    else printf 'FAIL  %2s %-12s %s  (want %s %s) %s\n' "$rc" "$got_state" "$name" "$want" "$want_state" "$detail"
         printf '%s\n' "$out" | sed 's/^/      | /' | tail -n 8; fails=$((fails + 1)); fi
}
# success
case_  0 written     "committed build, same ledger, same layer: written"             none
case_  0 written     "replaces a stale record from an earlier build"                 stale
case_  0 written     "rewrites a record that is already current"                     match
case_  0 written     "NOTHING TO DO now (record already there) is fine"              match 'now_code|0'
case_  0 written     "result 44 (VACUUM failed) still records the committed build"   none  'run_result|44'
# the build failed or is not recorded
case_ 61 absent      "no committed run at all"                                       none  'run|'
case_ 61 invalidated "no committed run, and the old record is stale"                 stale 'run|'
case_ 61 absent      "the run was not committed"                                     none  'run_committed|no'
case_ 61 absent      "the run ended 43 (commit not confirmed)"                       none  'run_result|43'
case_ 61 absent      "a later run attempted a commit without success"                none  'later_attempts|/tmp/fd_section4_refresh_20261015T041000Z '
case_ 61 kept        "later failed attempt, old record still matches the layer"      match 'later_attempts|/tmp/fd_section4_refresh_20261015T041000Z '
case_ 61 invalidated "old record matches but the assessment refuses it"              match 'run|' 'old_code|10'
case_ 61 invalidated "later failed attempt changed the layer: old record moved aside" match 'later_attempts|/tmp/x ' "live_stamp|$OTHER"
# missing or incomplete layer
case_ 63 absent      "assessment 11: module not installed / no layer"               none  'now_code|11' 'live_stamp|'
case_ 63 invalidated "assessment 11 with an old record: moved aside"                 match 'now_code|11' 'live_stamp|'
case_ 63 absent      "assessment 22: layer anomaly"                                  none  'now_code|22'
case_ 63 absent      "assessment 2: could not complete"                              none  'now_code|2'
case_ 63 absent      "assessment with the record is not NOTHING TO DO (e.g. 06c)"    none  'cand_code|10'
case_ 63 invalidated "06c fails with the record: even a matching old record goes"   match 'cand_code|10' 'old_code|10'
# stale
case_ 62 absent      "the ledger changed since the build"                            none  "now_fp|$FP_LEDGER"
case_ 62 invalidated "a replacement since the build: old record moved aside"         match "now_fp|$FP_NEW"
case_ 62 absent      "the layer in place is another build (refresh time differs)"   none  "live_stamp|$OTHER"
WANT_TEXT="the build's refresh time could not be read" \
case_ 62 absent      "the build's refresh time could not be read"                    none  'built|'
WANT_TEXT="the build's refresh time could not be read" \
case_ 62 absent      "both refresh times empty: equal, still refused"               none  'built|' 'live_stamp|'
WANT_TEXT="the live refresh time could not be read" \
case_ 62 absent      "the live refresh time could not be read"                       none  'live_stamp|unreadable'
WANT_TEXT="the live refresh time could not be read" \
case_ 62 invalidated "live time unreadable: a matching old record is not kept"       match 'live_stamp|unreadable'
WANT_TEXT="is not the one that build wrote" \
case_ 62 absent      "another build in place: the reason names both refresh times"  none  "live_stamp|$OTHER"
# writing or verifying fails
case_ 64 invalidated "the record in place does not verify: moved aside"              none  'final_code|10'
case_ 64 invalidated "the record in place has the wrong mode: moved aside"           none  'test_final_meta|0:644'
case_ 64 invalidated "the state folder has the wrong mode: moved aside"              none  'test_dir_meta|0:755'
: > "$W/a_file"
WANT_TEXT="could NOT be moved aside" \
case_ 64 unknown     "a stale record cannot be moved aside: 64 unknown, never kept"  stale_locked "now_fp|$FP_NEW"
case_ 64 absent      "the state folder cannot be created"                            none  "test_state_dir|$W/a_file/state"
case_ 64 absent      "the record cannot be put in place (state.json is a directory)" dirtarget
# could not run
case_  2 unchanged   "a pinned file differs: nothing changed"                        stale 'sha:10_assess.sh|0000'
# an unexpected abort (a failing command outside every handled path) is never a success
n=$((n + 1)); mkdir -p "$W/abort/state"
sed 's#^cd /$#cd /; false#' "$TOOL" > "$W/abort/13.sh"
{ sed 's/^/sha:/' <<<"$PINS"; echo "test_state_dir|$W/abort/state"; } > "$W/abort/facts.txt"
rc=0; out=$(bash "$W/abort/13.sh" --facts "$W/abort/facts.txt" 2>&1) || rc=$?
if [ "$rc" != 0 ] && grep -qx 'RECORD_STATE=unknown' <<<"$out" && grep -qx "RECORD_RESULT=$rc" <<<"$out" && [ ! -e "$W/abort/state/state.json" ]; then
    echo "PASS  $rc unknown      an unexpected abort reports unknown and its non-zero code"
else echo "FAIL  unexpected abort ($rc): $(tail -n 2 <<<"$out" | tr '\n' ' ')"; fails=$((fails + 1)); fi
n=$((n + 1)); rc=0; out=$(bash "$TOOL" --bogus 2>&1) || rc=$?
if [ "$rc" = 2 ] && [ "$(grep -c '^RECORD_RESULT=' <<<"$out")" = 1 ]; then echo "PASS   2 unchanged    unknown argument (one marker set only)"; else echo "FAIL  unknown argument ($rc)"; fails=$((fails + 1)); fi
echo "------------------------------------------------------------"
echo "$n cases: $((n - fails)) PASS, $fails FAIL"
[ "$fails" = 0 ]
