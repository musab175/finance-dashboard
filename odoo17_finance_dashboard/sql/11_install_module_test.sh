#!/usr/bin/env bash
# =============================================================================
# 11_install_module_test.sh - controlled tests for 11_install_module.sh. 2026-10-12.
#
# MADE-UP FACTS ONLY. No database, no Odoo, no sudo, no service is touched. Each
# case writes a facts file to a private temporary directory and runs
#   bash 11_install_module.sh --facts FILE [--dry-run]
# where the install itself is a stand-in whose outcome the facts decide.
#
# Every case checks TWO things: the exit code, and INSTALL_EXECUTED - so a
# refused pre-check is proven never to reach the install command.
#
# BASE = a clean post-replacement state and a successful install, so BASE
# alone must give exit 0 with INSTALL_EXECUTED=yes. Cases append overrides.
# Usage:  bash 11_install_module_test.sh      exit 0 only if every case passes
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BASE='pre_assess_code|11
pre_assess_verdict|INSTALL + REFRESH
pre_module_state|absent
pre_pending_modules|
odoo_service|inactive
odoo_processes|0
odoo_bin_ok|true
conf_readable|true
conf_db_host|127.0.0.1
conf_db_port|5432
conf_addons_paths|/usr/lib/python3/dist-packages/odoo/addons,/mnt/data/app/odoo/custom
module_copies|1
module_copy_paths|/mnt/data/app/odoo/custom
test_install_rc|0
post_module_state|installed
post_present:finance_dashboard_daily|true
post_present:finance_dashboard_arap_daily|true
post_present:finance_dashboard_aging_daily|true
post_present:finance_dashboard_expense_daily|true
post_present:finance_dashboard_coverage|true
post_rows:finance_dashboard_daily|0
post_rows:finance_dashboard_arap_daily|0
post_rows:finance_dashboard_aging_daily|0
post_rows:finance_dashboard_expense_daily|0
post_rows:finance_dashboard_coverage|0
post_provisioned_by|orm
post_schema_money_bad|0
post_schema_aging_bad|0
post_schema_index_missing|
post_schema_grain_missing|
post_assess_code|10
post_assess_verdict|REFRESH'

INSTALLED=('pre_assess_code|10' 'pre_assess_verdict|REFRESH' 'pre_module_state|installed')

pass=0
fail=0
case_() {   # case_ EXPECTED_EXIT EXPECTED_EXECUTED "name" "flags" [override lines...]
    local want=$1 want_exec=$2 name=$3 flags=$4 out code=0 got_exec first
    shift 4
    { printf '%s\n' "$BASE"; if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi; } > "$WORK/facts"
    # shellcheck disable=SC2086
    out=$(bash "$HERE/11_install_module.sh" $flags --facts "$WORK/facts" 2>&1) || code=$?
    got_exec=$(awk -F= '/^INSTALL_EXECUTED=/ {v = $2} END {print v}' <<<"$out")
    first=$(awk '/^  - / {sub(/^  - /, ""); print; exit}' <<<"$out")
    if [ "$code" = "$want" ] && [ "$got_exec" = "$want_exec" ]; then
        pass=$((pass + 1))
        printf 'PASS  %2s  exec=%-3s  %-44s %s\n' "$code" "$got_exec" "$name" "$first"
    else
        fail=$((fail + 1))
        printf 'FAIL  %2s  exec=%-3s  %-44s expected %s exec=%s\n' "$code" "$got_exec" "$name" "$want" "$want_exec"
        printf '%s\n' "$out" | sed 's/^/        /'
    fi
}

echo "--- success, and dry run ---"
case_  0 yes "clean state, install verified"             ""
case_  0 no  "dry run, every pre-check passes"            "--dry-run"

echo "--- module already installed: refuse (33), nothing run ---"
case_ 33 no  "installed, assessment REFRESH"              "" "${INSTALLED[@]}"
case_ 33 no  "installed, assessment NOTHING TO DO"        "" 'pre_assess_code|0' 'pre_assess_verdict|NOTHING TO DO' 'pre_module_state|installed'
case_ 33 no  "inconsistent: INSTALL + REFRESH but installed" "" 'pre_module_state|installed'

echo "--- intermediate or unknown module state: refuse (33), nothing run ---"
case_ 33 no  "state 'to install'"                         "" 'pre_assess_code|21' 'pre_assess_verdict|STOP: pending modules' 'pre_module_state|to install'
case_ 33 no  "state 'to upgrade'"                         "" 'pre_assess_code|21' 'pre_assess_verdict|STOP: pending modules' 'pre_module_state|to upgrade'
case_ 33 no  "state 'to remove'"                          "" 'pre_assess_code|21' 'pre_assess_verdict|STOP: pending modules' 'pre_module_state|to remove'
case_ 33 no  "state 'uninstallable'"                      "" 'pre_assess_code|21' 'pre_assess_verdict|STOP: pending modules' 'pre_module_state|uninstallable'
case_ 33 no  "state cannot be determined"                 "" 'pre_module_state|'
case_ 33 no  "another module pending (assessment 21)"     "" 'pre_assess_code|21' 'pre_assess_verdict|STOP: pending modules' 'pre_pending_modules|stock:to upgrade'

echo "--- wrong assessment verdict: refuse (33), nothing run ---"
case_ 33 no  "assessment STOP: wrong target"              "" 'pre_assess_code|20' 'pre_assess_verdict|STOP: wrong target' 'pre_module_state|'
case_ 33 no  "assessment STOP: layer anomaly"             "" 'pre_assess_code|22' 'pre_assess_verdict|STOP: layer anomaly'
case_ 33 no  "assessment did not complete"                "" 'pre_assess_code|2' 'pre_assess_verdict|ERROR' 'pre_module_state|'
case_ 33 no  "assessment aborted (exit 1)"                "" 'pre_assess_code|1' 'pre_assess_verdict|' 'pre_module_state|'

echo "--- Odoo not stopped: refuse (33), nothing run ---"
case_ 33 no  "service active"                             "" 'odoo_service|active'
case_ 33 no  "service activating"                         "" 'odoo_service|activating'
case_ 33 no  "service stopped but a process still runs"   "" 'odoo_processes|2'

echo "--- environment and addons path: refuse (33), nothing run ---"
case_ 33 no  "two copies on the addons path"              "" 'module_copies|2' 'module_copy_paths|/usr/lib/python3/dist-packages/odoo/custom,/mnt/data/app/odoo/custom'
case_ 33 no  "no copy on the addons path"                 "" 'module_copies|0' 'module_copy_paths|'
case_ 33 no  "config unreadable"                          "" 'conf_readable|false'
case_ 33 no  "config points Odoo at a remote host"        "" 'conf_db_host|10.0.0.99'
case_ 33 no  "config points Odoo at another port"         "" 'conf_db_port|5433'
case_ 33 no  "odoo binary missing"                        "" 'odoo_bin_ok|false'
case_ 33 no  "dry run with a failing pre-check"           "--dry-run" 'odoo_service|active'

echo "--- install ran, post-check fails ---"
case_ 30 yes "odoo exits 1"                               "" 'test_install_rc|1' 'post_module_state|to install'
case_ 31 yes "odoo exits 0, module absent"                "" 'post_module_state|absent'
case_ 31 yes "odoo exits 0, module 'to install'"          "" 'post_module_state|to install'
case_ 32 yes "installed, 4 of 5 tables"                   "" 'post_present:finance_dashboard_coverage|false'
case_ 32 yes "installed, SQL-path tables"                 "" 'post_provisioned_by|sql'
case_ 32 yes "installed, money column wrong"              "" 'post_schema_money_bad|1'
case_ 32 yes "installed, provisioning index missing"      "" 'post_schema_index_missing|finance_dashboard_arap_uk'
case_ 32 yes "installed, tables not empty"                "" 'post_rows:finance_dashboard_daily|12'
case_ 32 yes "installed, Section 2 says pending modules"  "" 'post_assess_code|21' 'post_assess_verdict|STOP: pending modules'
case_ 32 yes "installed, Section 2 says layer anomaly"    "" 'post_assess_code|22' 'post_assess_verdict|STOP: layer anomaly'

echo
echo "$((pass + fail)) cases: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
