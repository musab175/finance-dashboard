#!/usr/bin/env bash
# =============================================================================
# 10_assess_test.sh - decision-logic tests for 10_assess.sh. 2026-10-11.
#
# MADE-UP FACTS ONLY. No database, no sudo, no server state is read or changed.
# Each case writes a facts file into a private temporary directory (removed on
# exit) and runs:  bash 10_assess.sh --facts FILE
# The verdict must match the expected exit code.
#
# BASE is a healthy installed layer whose state.json proves it was built from
# exactly this data, so BASE alone must give NOTHING TO DO. Each case appends
# overrides; a later key replaces an earlier one.
#
# Usage:  bash 10_assess_test.sh        exit 0 only if every case passes
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BASE='hostname|gft-odoo-report
socket|true
database|gftuae
port|5432
data_directory|/mnt/data/postgres/16/main
read_only|on
server_version|16 (test)
odoo_tables|true
uuid|629148b0-9f15-11ee-bf49-2569bf801689
postmaster_start|2026-10-10T14:02:24.000000Z
max_aml_id|35400000
aml_n_tup_ins|36000000
aml_n_tup_upd|52000000
aml_n_tup_del|400000
track_counts|on
pg_database_oid|24863
system_identifier|7621987525607803622
stats_reset|2026-10-10 14:02:30.000000+00
module_state|installed
pending_modules|
present:finance_dashboard_daily|true
present:finance_dashboard_arap_daily|true
present:finance_dashboard_aging_daily|true
present:finance_dashboard_expense_daily|true
present:finance_dashboard_coverage|true
rows:finance_dashboard_daily|8743
rows:finance_dashboard_arap_daily|505500
rows:finance_dashboard_aging_daily|39761
rows:finance_dashboard_expense_daily|17731
rows:finance_dashboard_coverage|9
provisioned_by|orm
schema_money_bad|0
schema_aging_bad|0
schema_index_missing|
schema_grain_missing|
partner_idx|true
coverage_last_refresh|2026-10-11 05:08:00
gate_06c_rows|7
gate_06c_pass|7
gate_06c_fail|
state_present|true
state_uuid|629148b0-9f15-11ee-bf49-2569bf801689
state_postmaster_start|2026-10-10T14:02:24.000000Z
state_max_aml_id|35400000
state_aml_n_tup_ins|36000000
state_aml_n_tup_upd|52000000
state_aml_n_tup_del|400000'

NO_TABLES=('present:finance_dashboard_daily|false' 'present:finance_dashboard_arap_daily|false'
           'present:finance_dashboard_aging_daily|false' 'present:finance_dashboard_expense_daily|false'
           'present:finance_dashboard_coverage|false')
EMPTY=('rows:finance_dashboard_daily|0' 'rows:finance_dashboard_arap_daily|0'
       'rows:finance_dashboard_aging_daily|0' 'rows:finance_dashboard_expense_daily|0'
       'rows:finance_dashboard_coverage|0')
OTHER_UUID=00000000-0000-0000-0000-000000000000

pass=0
fail=0
case_() {   # case_ EXPECTED_EXIT "name" [override lines...]
    local want=$1 name=$2 out first code=0
    shift 2
    { printf '%s\n' "$BASE"; if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi; } > "$WORK/facts"
    out=$(bash "$HERE/10_assess.sh" --facts "$WORK/facts" 2>&1) || code=$?
    first=$(awk '/^  - / {sub(/^  - /, ""); print; exit}' <<<"$out")
    if [ "$code" = "$want" ]; then
        pass=$((pass + 1))
        printf 'PASS  %2s  %-46s %s\n' "$code" "$name" "$first"
    else
        fail=$((fail + 1))
        printf 'FAIL  %2s  %-46s expected %s\n' "$code" "$name" "$want"
        printf '%s\n' "$out" | sed 's/^/        /'
    fi
}

echo "--- the healthy case ---"
case_  0 "installed, proven by state.json"

echo "--- STOP: wrong target (20) ---"
case_ 20 "wrong hostname"                         'hostname|some-other-host'
case_ 20 "not a Unix-socket connection"           'socket|false'
case_ 20 "wrong database name"                    'database|postgres'
case_ 20 "wrong cluster (data directory)"         'data_directory|/var/lib/postgresql/16/main'
case_ 20 "not an Odoo database"                   'odoo_tables|false'
case_ 20 "different Odoo database (uuid)"         "uuid|$OTHER_UUID" "state_uuid|$OTHER_UUID"
case_ 20 "state file from another database"       "state_uuid|$OTHER_UUID"
case_ 20 "wrong target outranks pending modules"  'socket|false' 'pending_modules|sale:to install'

echo "--- ERROR: the assessment cannot proceed (2) ---"
case_  2 "read-only guard not in force"           'read_only|off'
case_  2 "state file exists but unreadable"       'state_present|unreadable'

echo "--- STOP: pending modules (21) ---"
case_ 21 "another module pending removal"         'pending_modules|sale_management:to remove'
case_ 21 "this module stuck in to install"        'module_state|to install' "pending_modules|odoo17_finance_dashboard:to install"
case_ 21 "this module uninstallable"              'module_state|uninstallable'
case_ 21 "pending outranks a layer anomaly"       'pending_modules|stock:to upgrade' 'provisioned_by|sql'

echo "--- STOP: layer anomaly (22) ---"
case_ 22 "incomplete layer, 3 of 5"               'present:finance_dashboard_aging_daily|false' 'present:finance_dashboard_coverage|false'
case_ 22 "installed but no tables"                "${NO_TABLES[@]}"
case_ 22 "tables present, module absent"          'module_state|absent'
case_ 22 "SQL-path tables under the ORM module"   'provisioned_by|sql'
case_ 22 "money column not numeric(18,2)"         'schema_money_bad|1'
case_ 22 "aging amounts double precision"         'schema_aging_bad|2'
case_ 22 "provisioning index missing"             'schema_index_missing|finance_dashboard_arap_uk'
case_ 22 "no unique index on a grain"             'schema_grain_missing|finance_dashboard_expense_daily'
case_ 22 "anomaly outranks refresh reasons"       'provisioned_by|sql' 'state_present|false'

echo "--- INSTALL + REFRESH (11) ---"
case_ 11 "after replacement: module absent"       'module_state|absent' "${NO_TABLES[@]}" 'state_postmaster_start|2026-10-09T14:02:11.000000Z'
case_ 11 "module uninstalled, no tables"          'module_state|uninstalled' "${NO_TABLES[@]}"
case_ 11 "module absent, no state file"           'module_state|absent' "${NO_TABLES[@]}" 'state_present|false'

echo "--- REFRESH (10) ---"
case_ 10 "just installed: tables empty"           "${EMPTY[@]}" 'partner_idx|false' 'gate_06c_pass|0'
case_ 10 "06c fails"                              'gate_06c_pass|6' 'gate_06c_fail|expense    = opex+cogs+dep'
case_ 10 "no state record"                        'state_present|false' 'state_uuid|' 'state_postmaster_start|' 'state_max_aml_id|' 'state_aml_n_tup_ins|' 'state_aml_n_tup_upd|' 'state_aml_n_tup_del|'
case_ 10 "state file is not a state record"       'state_present|invalid'
case_ 10 "cluster restarted since last success"   'state_postmaster_start|2026-10-09T14:02:11.000000Z'
case_ 10 "new ledger lines since last success"    'state_max_aml_id|35399999'
case_ 10 "partner index missing, layer populated" 'partner_idx|false'

echo "--- REFRESH (10): ledger statistics, Option B ---"
case_ 10 "existing line edited (e.g. draft posted)"  'aml_n_tup_upd|52000003'
case_ 10 "line inserted, counted"                    'aml_n_tup_ins|36000001'
case_ 10 "line deleted"                              'aml_n_tup_del|400001'
case_ 10 "statistics reset: counts went down"        'aml_n_tup_ins|0' 'aml_n_tup_upd|0' 'aml_n_tup_del|0'
case_ 10 "track_counts off"                          'track_counts|off'
case_ 10 "state file without ledger counts"          'state_aml_n_tup_ins|' 'state_aml_n_tup_upd|' 'state_aml_n_tup_del|'

echo
echo "$((pass + fail)) cases: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
