#!/usr/bin/env bash
# =============================================================================
# 12_refresh_test.sh - controlled tests for 12_refresh.sh. 2026-10-13.
#
# MADE-UP FACTS ONLY. No database, no Odoo, no sudo, no service is touched. Each
# case writes one facts file - the pre-check facts, the driver's FD4 output
# lines, and the facts a fresh connection would read after the transaction -
# and runs
#   bash 12_refresh.sh --facts FILE <mode flags>
# where odoo shell is a stand-in whose output and exit status the facts supply.
#
# Every case checks FIVE things: the exit code, TRANSACTION_EXECUTED,
# TRANSACTION_COMMITTED, VACUUM_EXECUTED, and whether RECORD_FINGERPRINT_JSON
# was printed. So a refusal is proven never to start Odoo, and a test mode is
# proven never to vacuum or print the fingerprint. "-" means the marker must be
# absent (argument errors stop before any marker is printed).
#
# BASE = a REFRESH state in which every pre-check passes; POST = a fresh check
# that agrees with the commit; driver VARIANTS = the driver's possible outputs.
# The 12_refresh.sh driver itself is tested by 12a_refresh_transaction_test.py.
# Usage:  bash 12_refresh_test.sh      exit 0 only if every case passes
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

UUID=629148b0-9f15-11ee-bf49-2569bf801689
START=2026-10-13T05:12:34.567890Z
PRE_STAMP='2026-10-13 07:00:00.000000'
NEW_STAMP='2026-10-13 09:00:00.123456'
FP='{"uuid": "629148b0-9f15-11ee-bf49-2569bf801689", "postmaster_start": "2026-10-13T05:12:34.567890Z", "max_aml_id": "30123456", "aml_n_tup_ins": "0", "aml_n_tup_upd": "0", "aml_n_tup_del": "0"}'
PINS=$(bash "$HERE/12_refresh.sh" --list-pins)

BASE="$(sed 's/^/file_sha:/' <<<"$PINS")
odoo_reads:folder/00_guard_account_types.sql|true
odoo_reads:folder/12b_clear_upsert_tables.sql|true
odoo_reads:folder/06b_validate_live_inline.sql|true
odoo_reads:folder/06c_validate_cross_table.sql|true
pre_assess_code|10
pre_assess_verdict|REFRESH
pre_fingerprint_json|$FP
pre_module_state|installed
pre_pending_modules|
pre_rows:finance_dashboard_daily|8756
pre_rows:finance_dashboard_arap_daily|506202
pre_rows:finance_dashboard_aging_daily|39805
pre_rows:finance_dashboard_expense_daily|17747
pre_rows:finance_dashboard_coverage|9
pre_stamp|$PRE_STAMP
odoo_service|inactive
odoo_processes|0
odoo_bin_ok|true
conf_readable|true
conf_db_host|False
conf_db_port|False
conf_addons_paths|/mnt/enterprise-addons/addons_ent/addons,/mnt/data/app/odoo/custom
module_copies|1
module_copy_paths|/mnt/data/app/odoo/custom
test_odoo_rc|0
test_vacuum_rc|0"

POST="post_module_state|installed
post_present:finance_dashboard_daily|true
post_present:finance_dashboard_arap_daily|true
post_present:finance_dashboard_aging_daily|true
post_present:finance_dashboard_expense_daily|true
post_present:finance_dashboard_coverage|true
post_rows:finance_dashboard_daily|8800
post_rows:finance_dashboard_arap_daily|506300
post_rows:finance_dashboard_aging_daily|39900
post_rows:finance_dashboard_expense_daily|17800
post_rows:finance_dashboard_coverage|9
post_provisioned_by|orm
post_schema_money_bad|0
post_schema_aging_bad|0
post_schema_index_missing|
post_schema_grain_missing|
post_partner_idx|true
post_postmaster_start|$START
post_stamp|$NEW_STAMP
post_stamp_ok|true
post_06c_rows|7
post_06c_pass|7"

driver() {   # $1 = variant -> the FD4 lines the driver would print
    local head_live="FD4|start|mode=live|inject=none|commit_allowed=yes|python=3.10.12"
    local head_test="FD4|start|mode=rollback-only|inject=none|commit_allowed=no|python=3.10.12"
    local ident="FD4|identity|repeatable read|gftuae|$UUID|$START"
    local guard="FD4|guard|PASS"
    local build="FD4|rows|before-clear|8756|506202|39805|17747|9
FD4|rows|after-clear|0|506202|39805|0|0
FD4|stage|02_backfill_daily.sql|102.36
FD4|stage|03_backfill_arap.sql|71.41
FD4|stage|04_backfill_expense_and_derived.sql|57.71"
    local gate="FD4|gate|06b|16/16|expected=16|108.20s
FD4|gate|06c|7/7|expected=7|0.20s"
    local final="FD4|rows|final|8800|506300|39900|17800|9
FD4|stamp|$NEW_STAMP"
    case "$1" in
        none) ;;
        committed) printf '%s\n' "$head_live" "$ident" "$guard" "$build" "$gate" "$final" \
            "FD4|commit|ATTEMPTED" "FD4|commit|DONE" "FD4|elapsed|345.60s" "FD4|outcome|COMMITTED" ;;
        test) printf '%s\n' "$head_test" "$ident" "$guard" "$build" "$gate" "$final" \
            "FD4|rollback|DONE" "FD4|elapsed|345.60s" \
            "FD4|outcome|ROLLED_BACK|test|every check passed - a test mode never commits" ;;
        la) printf '%s\n' "FD4|start|mode=rollback-only|inject=before-build|commit_allowed=no|python=3.10.12" \
            "$ident" "$guard" "FD4|residue|before-inject|0|0|0" "FD4|inject|before-build|1|1|1" \
            "$build" "FD4|residue|after-clear|0|0|0" "FD4|residue|after-build|0|0|0" "$gate" "$final" \
            "FD4|rollback|DONE" "FD4|elapsed|346.10s" \
            "FD4|outcome|ROLLED_BACK|test|every check passed - a test mode never commits" ;;
        lb) printf '%s\n' "FD4|start|mode=rollback-only|inject=after-build|commit_allowed=no|python=3.10.12" \
            "$ident" "$guard" "$build" "FD4|residue|before-inject|0|0|0" "FD4|inject|after-build|1|1|0" \
            "FD4|check|06b|sales|209195069.78|209195070.78|1.00|FAIL" \
            "FD4|gate|06b|15/16|expected=16|108.40s" \
            "FD4|check|06c|expense    = opex+cogs+dep|207361854.51|207361853.51|1.00|FAIL" \
            "FD4|gate|06c|6/7|expected=7|0.21s" "$final" \
            "FD4|expected-failures|match|got=06b sales 1.00; 06c expense    = opex+cogs+dep 1.00" \
            "FD4|rollback|DONE" "FD4|elapsed|346.30s" \
            "FD4|outcome|ROLLED_BACK|gate|2 check(s) failed: 06b sales 1.00; 06c expense    = opex+cogs+dep 1.00" ;;
        gate) printf '%s\n' "$head_live" "$ident" "$guard" "$build" \
            "FD4|check|06b|ar|26389427.99|26389428.00|0.01|FAIL" "FD4|gate|06b|15/16|expected=16|108.20s" \
            "FD4|gate|06c|7/7|expected=7|0.20s" "$final" "FD4|rollback|DONE" "FD4|elapsed|345.60s" \
            "FD4|outcome|ROLLED_BACK|gate|1 check(s) failed: 06b ar 0.01" ;;
        guard) printf '%s\n' "$head_live" "$ident" "FD4|guard|UNCLASSIFIED|asset_prepayments|1|1234|1234" \
            "FD4|rollback|DONE" "FD4|elapsed|0.40s" \
            "FD4|outcome|ROLLED_BACK|gate|account-type guard: 1 unclassified account_type(s)" ;;
        refused) printf '%s\n' "$head_live" "FD4|identity|repeatable read|gftuae|$UUID|2026-10-13T14:02:11.000000Z" \
            "FD4|rollback|DONE" "FD4|elapsed|0.30s" \
            "FD4|outcome|ROLLED_BACK|refused|cluster start time differs from the pre-check" ;;
        error) printf '%s\n' "$head_live" "$ident" "$guard" "FD4|rows|before-clear|8756|506202|39805|17747|9" \
            "FD4|rollback|DONE" "FD4|elapsed|61.00s" \
            "FD4|outcome|ROLLED_BACK|error|LockNotAvailable 55P03: canceling statement due to lock timeout" ;;
        unknown) printf '%s\n' "$head_live" "$ident" "$guard" "$build" "$gate" "$final" "FD4|commit|ATTEMPTED" \
            "FD4|commit|ERROR|OperationalError 08006: server closed the connection unexpectedly" \
            "FD4|rollback|ERROR|InterfaceError: connection already closed" "FD4|elapsed|345.70s" \
            "FD4|outcome|UNKNOWN|OperationalError 08006: server closed the connection unexpectedly" ;;
        attempted) printf '%s\n' "$head_live" "$ident" "$guard" "$build" "$gate" "$final" "FD4|commit|ATTEMPTED" ;;
        test-committed) printf '%s\n' "$head_test" "$ident" "$guard" "$build" "$gate" "$final" \
            "FD4|commit|ATTEMPTED" "FD4|commit|DONE" "FD4|outcome|COMMITTED" ;;
        live-test) printf '%s\n' "$head_live" "$ident" "$guard" "$build" "$gate" "$final" "FD4|rollback|DONE" \
            "FD4|outcome|ROLLED_BACK|test|every check passed - a test mode never commits" ;;
        *) echo "unknown driver variant $1" >&2; exit 2 ;;
    esac
}

OUT=
CODE_GOT=
run_case() {   # flags variant [override lines...]
    local flags=$1 variant=$2
    shift 2
    { printf '%s\n' "$BASE" "$POST"; driver "$variant"
      if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi; } > "$WORK/facts"
    CODE_GOT=0
    # shellcheck disable=SC2086
    OUT=$(bash "$HERE/12_refresh.sh" $flags --facts "$WORK/facts" < /dev/null 2>&1) || CODE_GOT=$?
}

marker() {   # $1 = marker name -> its value, or "-" when it was not printed
    awk -v k="$1=" 'index($0, k) == 1 {v = substr($0, length(k) + 1); f = 1} END {print f ? v : "-"}' <<<"$OUT"
}

pass=0
fail=0
verdict() {   # ok name detail
    if [ "$1" = yes ]; then
        pass=$((pass + 1))
        printf 'PASS  %2s  %-58s %s\n' "$CODE_GOT" "$2" "$3"
    else
        fail=$((fail + 1))
        printf 'FAIL  %2s  %-58s %s\n' "$CODE_GOT" "$2" "$3"
        printf '%s\n' "$OUT" | sed 's/^/        /'
    fi
}

case_() {    # EXIT EXECUTED COMMITTED VACUUMED RECORD "name" "flags" variant [overrides...]
    local want=$1 w_exec=$2 w_comm=$3 w_vac=$4 w_rec=$5 name=$6 flags=$7 variant=$8
    local g_exec g_comm g_vac g_rec first ok=no
    shift 8
    run_case "$flags" "$variant" "$@"
    g_exec=$(marker TRANSACTION_EXECUTED)
    g_comm=$(marker TRANSACTION_COMMITTED)
    g_vac=$(marker VACUUM_EXECUTED)
    g_rec=$(awk '/^RECORD_FINGERPRINT_JSON=/ {f = 1} END {print f ? "yes" : "no"}' <<<"$OUT")
    first=$(awk '/^  - / {sub(/^  - /, ""); print; exit}' <<<"$OUT")
    if [ "$CODE_GOT" = "$want" ] && [ "$g_exec" = "$w_exec" ] && [ "$g_comm" = "$w_comm" ] \
            && [ "$g_vac" = "$w_vac" ] && [ "$g_rec" = "$w_rec" ]; then
        ok=yes
    fi
    verdict "$ok" "$name" "exec=$g_exec committed=$g_comm vacuum=$g_vac record=$g_rec | ${first:0:90}"
    if [ "$ok" = no ]; then
        echo "        expected exit=$want exec=$w_exec committed=$w_comm vacuum=$w_vac record=$w_rec"
    fi
}

text_case() {    # EXIT "name" "flags" variant "text that must appear" [overrides...]
    local want=$1 name=$2 flags=$3 variant=$4 needle=$5 ok=no
    shift 5
    run_case "$flags" "$variant" "$@"
    if [ "$CODE_GOT" = "$want" ] && [[ "$OUT" == *"$needle"* ]]; then ok=yes; fi
    verdict "$ok" "$name" "contains: ${needle:0:70}"
}

echo "--- success, the dry run and the test modes ---"
case_  0 yes yes yes yes "live: committed, verified, vacuumed"                 "--live" committed
case_  0 no  no  no  no  "dry run: every pre-check passes, nothing started"    "--dry-run" none
case_  0 no  no  no  no  "dry run of a test mode"                              "--dry-run --test-inject before-build" none
case_  0 yes no  no  no  "rollback-only: all checks passed, nothing committed" "--rollback-only" test
case_  0 yes no  no  no  "L-A: test rows cleared, all checks passed"           "--test-inject before-build" la
case_ 42 yes no  no  no  "L-B: exactly the expected failures, rolled back"     "--test-inject after-build" lb
text_case 0 "live: the fingerprint printed is the pre-check's, unchanged" "--live" committed "RECORD_FINGERPRINT_JSON=$FP"
text_case 0 "dry run: the driver gets the MODULE folder, not the addons folder" "--dry-run" none \
    "FD4_MODULE_DIR=/mnt/data/app/odoo/custom/odoo17_finance_dashboard "
text_case 0 "dry run: the command was not run"                         "--dry-run" none "the command above was NOT run"
text_case 42 "L-B: the expected-failures marker is reported"           "--test-inject after-build" lb "L-B expected failures: match"

echo "--- argument errors: exit 2, nothing started ---"
case_  2 -   -   -   no  "no mode given"                                       "" none
case_  2 -   -   -   no  "--live with --rollback-only"                         "--live --rollback-only" none
case_  2 -   -   -   no  "--live with --test-inject"                           "--live --test-inject after-build" none
case_  2 -   -   -   no  "--test-inject with an unknown value"                 "--test-inject sideways" none

echo "--- assessment verdict: refuse (40), nothing started ---"
case_ 40 no  no  no  no  "NOTHING TO DO"                 "--live" committed 'pre_assess_code|0' 'pre_assess_verdict|NOTHING TO DO'
case_ 40 no  no  no  no  "INSTALL + REFRESH"             "--live" committed 'pre_assess_code|11' 'pre_assess_verdict|INSTALL + REFRESH' 'pre_module_state|absent'
case_ 40 no  no  no  no  "STOP: wrong target"            "--live" committed 'pre_assess_code|20' 'pre_assess_verdict|STOP: wrong target'
case_ 40 no  no  no  no  "STOP: pending modules"         "--live" committed 'pre_assess_code|21' 'pre_assess_verdict|STOP: pending modules'
case_ 40 no  no  no  no  "STOP: layer anomaly"           "--live" committed 'pre_assess_code|22' 'pre_assess_verdict|STOP: layer anomaly'
case_ 40 no  no  no  no  "assessment did not complete"   "--live" committed 'pre_assess_code|2' 'pre_assess_verdict|ERROR'
case_ 40 no  no  no  no  "assessment aborted (exit 1)"   "--live" committed 'pre_assess_code|1' 'pre_assess_verdict|'
case_ 40 no  no  no  no  "assessment not run: its files differ" "--live" committed 'pre_assess_code|not-run' "file_sha:folder/10_assess.sh|$(printf '0%.0s' {1..64})"
case_ 40 no  no  no  no  "REFRESH but module state 'to upgrade'" "--live" committed 'pre_module_state|to upgrade'
case_ 40 no  no  no  no  "no fingerprint printed"        "--live" committed 'pre_fingerprint_json|'
case_ 40 no  no  no  no  "fingerprint not JSON"          "--live" committed 'pre_fingerprint_json|{not json'
case_ 40 no  no  no  no  "fingerprint incomplete"        "--live" committed 'pre_fingerprint_json|{"uuid": "629148b0-9f15-11ee-bf49-2569bf801689", "postmaster_start": "x"}'
case_ 40 no  no  no  no  "fingerprint of another database" "--live" committed 'pre_fingerprint_json|{"uuid": "other", "postmaster_start": "x", "max_aml_id": "1", "aml_n_tup_ins": "0", "aml_n_tup_upd": "0", "aml_n_tup_del": "0"}'

echo "--- Odoo, environment and module copy: refuse (40), nothing started ---"
case_ 40 no  no  no  no  "Odoo service active"           "--live" committed 'odoo_service|active'
case_ 40 no  no  no  no  "Odoo service activating"       "--rollback-only" test 'odoo_service|activating'
case_ 40 no  no  no  no  "service stopped, a process runs" "--live" committed 'odoo_processes|2'
case_ 40 no  no  no  no  "odoo binary missing"           "--live" committed 'odoo_bin_ok|false'
case_ 40 no  no  no  no  "config unreadable"             "--live" committed 'conf_readable|false'
case_ 40 no  no  no  no  "config: remote database host"  "--live" committed 'conf_db_host|10.0.0.99'
case_ 40 no  no  no  no  "config: database host by name" "--live" committed 'conf_db_host|erp.example.com'
case_ 40 no  no  no  no  "config: another port"          "--live" committed 'conf_db_port|5433'
case_ 40 no  no  no  no  "no module copy on the addons path" "--live" committed 'module_copies|0' 'module_copy_paths|'
case_ 40 no  no  no  no  "two module copies"             "--live" committed 'module_copies|2' 'module_copy_paths|/a,/b'
case_ 40 no  no  no  no  "the odoo user cannot read 06b" "--live" committed 'odoo_reads:folder/06b_validate_live_inline.sql|false'
case_ 40 no  no  no  no  "dry run with a failing pre-check" "--dry-run" none 'odoo_service|active'

echo "--- pinned files: refuse (40), nothing started ---"
while IFS='|' read -r key _; do
    case_ 40 no no no no "differs: $key" "--live" committed "file_sha:$key|$(printf 'f%.0s' {1..64})"
done <<<"$PINS"
case_ 40 no  no  no  no  "missing: folder/12b_clear_upsert_tables.sql" "--live" committed 'file_sha:folder/12b_clear_upsert_tables.sql|missing'
case_ 40 no  no  no  no  "missing: module/sql/03_backfill_arap.sql"    "--live" committed 'file_sha:module/sql/03_backfill_arap.sql|missing'

echo "--- the transaction rolled back: 41 (technical) or 42 (checks) ---"
case_ 41 yes no  no  no  "driver refused: cluster restarted"          "--live" refused
case_ 41 yes no  no  no  "driver error: lock timeout"                 "--live" error
case_ 41 yes no  no  no  "odoo shell did not start (no output, exit 1)" "--live" none 'test_odoo_rc|1'
case_ 41 yes no  no  no  "test passed but odoo shell exited 1"        "--rollback-only" test 'test_odoo_rc|1'
case_ 41 yes no  no  no  "--live run, driver reported a test"         "--live" live-test
case_ 42 yes no  no  no  "guard failed"                               "--live" guard
case_ 42 yes no  no  no  "06b failed"                                 "--live" gate
case_ 42 yes no  no  no  "06b failed in a rollback-only run"          "--rollback-only" gate

echo "--- commit not confirmed: 43, no fingerprint, no VACUUM ---"
case_ 43 yes unknown no no "commit raised an error"                   "--live" unknown
case_ 43 yes unknown no no "commit attempted, then no outcome"        "--live" attempted 'test_odoo_rc|137'
case_ 43 yes unknown no no "a test run reported a commit"             "--rollback-only" test-committed
case_ 43 yes yes no  no  "committed, then the cluster restarted"      "--live" committed 'post_postmaster_start|2026-10-13T14:02:11.000000Z'
case_ 43 yes yes no  no  "committed, refresh time differs"            "--live" committed 'post_stamp|2026-10-13 09:30:00.000000'
case_ 43 yes yes no  no  "committed, refresh time unreadable"         "--live" committed 'post_stamp_ok|false'
case_ 43 yes yes no  no  "committed, a row count differs"             "--live" committed 'post_rows:finance_dashboard_daily|8799'
case_ 43 yes yes no  no  "committed, 06c 6/7 from a fresh connection" "--live" committed 'post_06c_pass|6'
case_ 43 yes yes no  no  "committed, partner index missing"           "--live" committed 'post_partner_idx|false'
case_ 43 yes yes no  no  "committed, module state unreadable"         "--live" committed 'post_module_state|unknown'
case_ 43 yes yes no  no  "committed, a table gone"                    "--live" committed 'post_present:finance_dashboard_coverage|false'
case_ 43 yes yes no  no  "committed, but odoo shell exited 1"         "--live" committed 'test_odoo_rc|1'
case_ 44 yes yes yes yes "committed and verified, VACUUM failed"      "--live" committed 'test_vacuum_rc|1'

echo "--- 43: what a fresh connection reports ---"
text_case 43 "uncertain commit, new data visible"    "--live" unknown "the NEW data is in place"
text_case 43 "uncertain commit, previous data kept"  "--live" unknown "NOT committed - the previous data is in place" "post_stamp|$PRE_STAMP"
text_case 43 "uncertain commit on a cold build"      "--live" unknown "the tables are as the install left them" 'pre_stamp|' 'post_stamp|'
text_case 43 "uncertain commit, cluster restarted"   "--live" unknown "the cluster restarted since the pre-check" 'post_postmaster_start|2026-10-14T14:02:00.000000Z'
text_case 43 "uncertain commit, refresh time other"  "--live" unknown "undetermined" 'post_stamp|2026-10-13 08:00:00.000000'

echo
echo "$((pass + fail)) cases: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
