#!/usr/bin/env bash
# =============================================================================
# 12_refresh.sh - Finance Dashboard bootstrap, SECTION 4: REFRESH. 2026-10-13.
#
# Rebuilds the reporting layer in ONE transaction and commits it only when every
# check passes. Nothing else: no install (Section 3), no backup and no state
# file (Section 6), and it never starts or stops Odoo.
#
#   1. Pre-checks, read-only   every file this run uses matches its pinned
#                              SHA-256 (the assessment's own files before it is
#                              run); a fresh Section 2 assessment says exactly
#                              REFRESH, and its fingerprint is kept - read
#                              before odoo shell starts, so before the build's
#                              snapshot; module installed; Odoo stopped, no Odoo
#                              process; Odoo's own database settings local;
#                              exactly one module copy; the odoo user can read
#                              the files the driver opens
#   2. The transaction         12a_refresh_transaction.py through `odoo shell`:
#                              identity, guard, clear, refresh_full(), 06b and
#                              06c, then COMMIT only if all of it passed
#   3. After a COMMIT          a FRESH connection confirms what was committed:
#                              the same cluster start time, the refresh time and
#                              row counts the transaction reported, 06c 7/7, the
#                              schema clean. Then VACUUM (ANALYZE) on the four
#                              churned tables. Then the fingerprint, for
#                              Section 6 to record.
#
# EXIT CODES
#   0   refreshed, verified and vacuumed - or a --dry-run or rollback-only test
#       passed. The result line and TRANSACTION_COMMITTED tell them apart.
#   40  a pre-check refused: odoo shell was never started, nothing was written
#   41  technical failure (SQL error, lock timeout, identity mismatch, Odoo did
#       not start or ended oddly): rolled back, previous data unchanged.
#       Correct the cause, then run again.
#   42  the guard or a check failed: rolled back, previous data unchanged.
#       Investigate - a re-run on the same data fails the same way.
#   43  the commit could not be confirmed: connection lost during COMMIT, a
#       restart, the fresh check disagrees, or odoo shell's exit status. A fresh
#       connection reports which data is in place. Never a success; no
#       fingerprint.
#   44  committed and verified, but VACUUM failed: the data is good and stays.
#       Run VACUUM (ANALYZE) by hand.
#   2   this script itself failed
# Any other exit code (1, 127, 141 ...) is an unexpected abort: an error.
#
# RECORD_FINGERPRINT_JSON=... is printed only for exit 0 and 44 of a --live run
# - never for a dry run or a test mode. It is the pre-check assessment's
# FINGERPRINT_JSON, unchanged. Section 6 records exactly that line, never a value
# read after the commit (approved rule, 2026-10-11).
#
# NEVER: VACUUM FULL, -i or -u, a retry, a write to state.json, starting or
# stopping Odoo, a change to the module copy.
#
# MODES - exactly one is required; with none the script does nothing:
#   --dry-run                      pre-checks only; nothing is started
#   --rollback-only                the whole transaction, then ROLLBACK
#   --test-inject before-build     L-A: made-up rows the clear must remove
#   --test-inject after-build      L-B: made-up rows the gate must catch
#                                  (both imply --rollback-only)
#   --live                         the real refresh - only with authorization
# The driver itself refuses to commit in a test mode. This script, too, never
# runs VACUUM or prints the fingerprint in one.
#
# LOGS: each run that starts odoo shell creates a NEW directory
# /tmp/fd_section4_refresh_<UTC time>, owned by the odoo user, mode 0750:
# odoo-shell.log, driver.out (the FD4 lines), driver.err, result.txt. Reading
# them needs sudo.
#
# USAGE
#   sudo bash 12_refresh.sh --dry-run
#   sudo bash 12_refresh.sh --rollback-only [--test-inject before-build|after-build]
#   sudo bash 12_refresh.sh --live
#   bash 12_refresh.sh --list-pins                  print the pinned hashes
#   bash 12_refresh.sh --facts FILE <mode>          (test) made-up facts and
#                                                   driver output; no Odoo
#
# The same folder must hold, all pinned: 12a_refresh_transaction.py,
# 12b_clear_upsert_tables.sql, 00_guard_account_types.sql,
# 06b_validate_live_inline.sql, 06c_validate_cross_table.sql, 10_assess.sh,
# 10a_assess_target.sql, 10b_assess_facts.sql.
# =============================================================================
set -euo pipefail

ODOO_BIN=/mnt/data/app/bin/odoo
ODOO_CONF=/mnt/data/app/odoo.conf
ODOO_USER=odoo
ODOO_SERVICE=odoo
DATABASE=gftuae
MODULE=odoo17_finance_dashboard
EXPECTED_UUID=629148b0-9f15-11ee-bf49-2569bf801689
SOCKET_DIR=/var/run/postgresql
SOCKET_PORT=5432
LOCK_TIMEOUT=60s
TABLES=(finance_dashboard_daily finance_dashboard_arap_daily
        finance_dashboard_aging_daily finance_dashboard_expense_daily
        finance_dashboard_coverage)
VACUUM_TABLES=(finance_dashboard_arap_daily finance_dashboard_aging_daily
               finance_dashboard_daily finance_dashboard_expense_daily)
# The SAME text 12a_refresh_transaction.py runs inside the transaction.
STAMP_SQL="SELECT COALESCE(to_char(max(last_refresh_at), 'YYYY-MM-DD HH24:MI:SS.US'), '') FROM finance_dashboard_coverage"

# ---- pinned SHA-256 of every file this run executes or makes Odoo execute ----
PIN_KEYS=(
    folder/12a_refresh_transaction.py
    folder/12b_clear_upsert_tables.sql
    folder/00_guard_account_types.sql
    folder/06b_validate_live_inline.sql
    folder/06c_validate_cross_table.sql
    folder/10_assess.sh
    folder/10a_assess_target.sql
    folder/10b_assess_facts.sql
    module/models/finance_dashboard_layer.py
    module/sql/02_backfill_daily.sql
    module/sql/03_backfill_arap.sql
    module/sql/04_backfill_expense_and_derived.sql
)
declare -A PIN=(
    # Section 4's own folder (Option A, approved 2026-10-13)
    [folder/12a_refresh_transaction.py]=848b1b2ea770326342e8d31d083d88021b725f9c9c2b0c7564bfba0929f59394
    [folder/12b_clear_upsert_tables.sql]=b8dc8c1fd6ec7b358cb53cbfd0d82f34b50175ff451a6c2e2c1942eddac0c32b
    [folder/00_guard_account_types.sql]=fb699289b9b8496710c42b45255ce52cad5e66e386eaf757460f8c301d66114a
    [folder/06b_validate_live_inline.sql]=dae76d6782878e646a970c980d09952e4715c07865f49a0afaadebb315e14f41
    [folder/06c_validate_cross_table.sql]=4c008824249f86bd2c1065c22eb32bea0687a2542d527ba2c21bdd71e6905708
    [folder/10_assess.sh]=067b7e4f11de389cb49caea4d902a547b6204c18c91f4d0e5d0306b4548870e5
    [folder/10a_assess_target.sql]=b6b9da8d51099f03c4ca82b5f109b73bf0a0430202f15671f50ac6e554bc340a
    [folder/10b_assess_facts.sql]=37809ddc91cc74a5bf7619dea032761b4e6ba64996444fd77d1f598db7637dab
    # the live module copy, read by refresh_full() (Step 0(a), 2026-10-13)
    [module/models/finance_dashboard_layer.py]=6e15e0ecb1dc91613d190f63ce625e852b33c7eef2728a8759dbd64f3d213368
    [module/sql/02_backfill_daily.sql]=f2097525d1629351311b3ef4f38e21ffc9d903a3b82cc91b3faf1f4ae56cd10d
    [module/sql/03_backfill_arap.sql]=4ee5439cb9a80c8bd97195f55dbcafbf32f263a4ab907c822bfac27d240bfdcf
    [module/sql/04_backfill_expense_and_derived.sql]=361b56e1290516a810d86fa9401a2d87fdfdfb994b4fe5015fb06cb6fcf830d7
)
# Files the assessment runs: checked BEFORE it is run, because it runs as root.
ASSESS_KEYS=(folder/10_assess.sh folder/10a_assess_target.sql
             folder/10b_assess_facts.sql folder/06c_validate_cross_table.sql)
# Files the driver executes; it re-checks each against the same pin.
DRIVER_KEYS=(module/models/finance_dashboard_layer.py module/sql/02_backfill_daily.sql
             module/sql/03_backfill_arap.sql module/sql/04_backfill_expense_and_derived.sql
             folder/00_guard_account_types.sql folder/12b_clear_upsert_tables.sql
             folder/06b_validate_live_inline.sql folder/06c_validate_cross_table.sql)
# Files the driver opens itself, as the odoo user.
ODOO_READ_KEYS=(folder/00_guard_account_types.sql folder/12b_clear_upsert_tables.sql
                folder/06b_validate_live_inline.sql folder/06c_validate_cross_table.sql)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
LIVE=0
ROLLBACK_ONLY=0
INJECT=none
FACTS_FILE=

usage() { echo "12_refresh.sh: $*" >&2; echo "RESULT=2"; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)       DRY_RUN=1; shift ;;
        --rollback-only) ROLLBACK_ONLY=1; shift ;;
        --live)          LIVE=1; shift ;;
        --test-inject)
            case "${2:-}" in
                before-build|after-build) INJECT=$2; ROLLBACK_ONLY=1; shift 2 ;;
                *) usage "--test-inject needs before-build or after-build" ;;
            esac ;;
        --facts)         FACTS_FILE=${2:?--facts needs a file}; shift 2 ;;
        --list-pins)
            for key in "${PIN_KEYS[@]}"; do printf '%s|%s\n' "$key" "${PIN[$key]}"; done
            exit 0 ;;
        *) usage "unknown argument: $1" ;;
    esac
done
if [ "$LIVE" = 1 ] && [ "$ROLLBACK_ONLY" = 1 ]; then
    usage "--live cannot be combined with --rollback-only or --test-inject"
fi
if [ "$LIVE" = 0 ] && [ "$ROLLBACK_ONLY" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    usage "choose a mode: --dry-run, --rollback-only, --test-inject before-build|after-build, or --live"
fi
if [ "$LIVE" = 1 ]; then TXN_MODE=live; else TXN_MODE=rollback-only; fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="/tmp/fd_section4_refresh_$STAMP"   # created new for each run that starts Odoo
LOG="$RUN_DIR/odoo-shell.log"
DRIVER_OUT="$RUN_DIR/driver.out"
DRIVER_ERR="$RUN_DIR/driver.err"
RESULT_FILE="$RUN_DIR/result.txt"
TRANSACTION_EXECUTED=no
COMMITTED=no
VACUUM_EXECUTED=no
VACUUM_RC=
NEED_VACUUM=no
FRESH=no
FRESH_READ=no
ODOO_RC=
CODE=
REFUSE=()
REASONS=()
CMD=()
D_OUTCOME= D_KIND= D_ATTEMPTED=0 D_DONE=0 D_STAMP= D_ROWS= D_EXPECTED=
declare -A F=()
fact() { printf '%s' "${F[$1]:-}"; }

load() {    # key|value lines on stdin -> F. A later line overrides an earlier one.
    local k v
    while IFS='|' read -r k v; do
        if [ -n "$k" ]; then F["$k"]=$v; fi
    done
}

die() {
    echo "SECTION 4 ERROR: $*" >&2
    echo "TRANSACTION_EXECUTED=$TRANSACTION_EXECUTED"
    if [ "$TRANSACTION_EXECUTED" = yes ]; then echo "TRANSACTION_COMMITTED=unknown"
    else echo "TRANSACTION_COMMITTED=no"; fi
    echo "VACUUM_EXECUTED=$VACUUM_EXECUTED"
    echo "RESULT=2"
    exit 2
}

q() {       # one read-only SQL file through the local socket -> key|value lines
    sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on' \
        psql -X -At -F '|' -v ON_ERROR_STOP=1 \
             -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" -f "$1"
}

q_sql() {   # one read-only statement through the local socket -> its value
    sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on' \
        psql -X -At -v ON_ERROR_STOP=1 \
             -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" -c "$1"
}

pin_path() {    # pinned key -> the file on this server
    case "$1" in
        folder/*) printf '%s' "$HERE/${1#folder/}" ;;
        module/*) if [ -n "$(fact module_dir)" ]; then
                      printf '%s' "$(fact module_dir)/${1#module/}"
                  fi ;;
    esac
}

pin_ok() {      # pinned key -> true when the file on disk matches its pin
    [ "$(fact "file_sha:$1")" = "${PIN[$1]}" ]
}

assess() {      # run Section 2 afresh; keep its exit code, verdict and fingerprint
    local out code=0
    out=$(bash "$HERE/10_assess.sh" 2>&1) || code=$?
    F[pre_assess_code]=$code
    F[pre_assess_verdict]=$(awk -F= '/^VERDICT=/ {v = $2} END {print v}' <<<"$out")
    F[pre_fingerprint_json]=$(awk '/^FINGERPRINT_JSON=/ {sub(/^FINGERPRINT_JSON=/, ""); v = $0} END {print v}' <<<"$out")
}

layer_facts() {  # $1 = pre|post, $2 = soft : module state + layer facts (10b)
    local out k v
    if ! out=$(q "$HERE/10b_assess_facts.sql"); then
        if [ "${2:-}" = soft ]; then   # after the transaction: record, never abort
            F["$1_module_state"]=unknown
            return 0
        fi
        die "10b_assess_facts.sql failed (psql message above)"
    fi
    while IFS='|' read -r k v; do
        if [ -n "$k" ]; then F["$1_$k"]=$v; fi
    done <<<"$out"
}

env_facts() {    # service, processes, binary, and three keys of the active config
    local out
    F[odoo_service]=$(systemctl is-active "$ODOO_SERVICE" 2>/dev/null || true)
    F[odoo_processes]=$(pgrep -fc -- "$ODOO_BIN" || true)
    if [ -x "$ODOO_BIN" ]; then F[odoo_bin_ok]=true; else F[odoo_bin_ok]=false; fi
    if [ ! -r "$ODOO_CONF" ]; then F[conf_readable]=false; return; fi
    F[conf_readable]=true
    out=$(python3 - "$ODOO_CONF" "$MODULE" <<'PY'
import configparser, os, sys
cp = configparser.ConfigParser(interpolation=None, strict=False)
cp.read(sys.argv[1])
opt = cp['options'] if cp.has_section('options') else {}
host = (opt.get('db_host') or '').strip()
port = (opt.get('db_port') or '').strip()
paths = [p.strip() for p in (opt.get('addons_path') or '').split(',') if p.strip()]
found = [p for p in paths if os.path.isfile(os.path.join(p, sys.argv[2], '__manifest__.py'))]
print('conf_db_host|' + host)
print('conf_db_port|' + port)
print('conf_addons_paths|' + ','.join(paths))
print('module_copies|' + str(len(found)))
print('module_copy_paths|' + ','.join(found))
PY
    ) || die "python3 could not read $ODOO_CONF"
    load <<<"$out"
}

module_dir_fact() {  # the ONE addons-path entry holding the module -> the module itself
    if [ "$(fact module_copies)" = 1 ]; then
        F[module_dir]="$(fact module_copy_paths)/$MODULE"
    else
        F[module_dir]=
    fi
}

file_facts() {   # sha256 of every pinned file, and which ones the odoo user can read
    local key path
    for key in "${PIN_KEYS[@]}"; do
        path=$(pin_path "$key")
        if [ -n "$path" ] && [ -f "$path" ]; then
            F["file_sha:$key"]=$(sha256sum "$path" | awk '{print $1}')
        else
            F["file_sha:$key"]=missing
        fi
    done
    for key in "${ODOO_READ_KEYS[@]}"; do
        path=$(pin_path "$key")
        if [ -n "$path" ] && sudo -u "$ODOO_USER" test -r "$path"; then
            F["odoo_reads:$key"]=true
        else
            F["odoo_reads:$key"]=false
        fi
    done
}

parse_fingerprint() {   # pre_fingerprint_json -> fp_valid, fp_uuid, fp_postmaster_start
    local out
    out=$(python3 - "$(fact pre_fingerprint_json)" <<'PY'
import json, sys
keys = ("uuid", "postmaster_start", "max_aml_id",
        "aml_n_tup_ins", "aml_n_tup_upd", "aml_n_tup_del")
try:
    fp = json.loads(sys.argv[1])
except ValueError:
    fp = None
ok = isinstance(fp, dict) and all(isinstance(fp.get(k), str) and fp.get(k) for k in keys)
print("fp_valid|" + ("true" if ok else "false"))
if ok:
    print("fp_uuid|" + fp["uuid"])
    print("fp_postmaster_start|" + fp["postmaster_start"])
PY
    ) || die "python3 could not read the assessment's fingerprint"
    load <<<"$out"
}

decide_pre() {   # facts -> REFUSE[]. Reads nothing else.
    local code m key sha
    for key in "${PIN_KEYS[@]}"; do
        sha=$(fact "file_sha:$key")
        if [ "$sha" = missing ] || [ -z "$sha" ]; then
            REFUSE+=("$key is missing")
        elif ! pin_ok "$key"; then
            REFUSE+=("$key does not match its approved hash (found ${sha:0:12}...)")
        fi
    done
    for key in "${ODOO_READ_KEYS[@]}"; do
        [ "$(fact "odoo_reads:$key")" = true ] \
            || REFUSE+=("the $ODOO_USER user cannot read $key - the driver opens it itself")
    done
    code=$(fact pre_assess_code)
    case "$code" in
        10) ;;
        0)  REFUSE+=("the assessment says NOTHING TO DO - the layer already matches the last successful build") ;;
        11) REFUSE+=("the assessment says INSTALL + REFRESH - the module is not installed; Section 3 first") ;;
        20) REFUSE+=("the assessment says STOP: wrong target - not the expected reporting environment") ;;
        21) REFUSE+=("the assessment says STOP: pending modules - investigate manually") ;;
        22) REFUSE+=("the assessment says STOP: layer anomaly - investigate; a refresh is not assumed safe") ;;
        2)  REFUSE+=("the Section 2 assessment did not complete - the environment cannot be confirmed") ;;
        not-run) REFUSE+=("the Section 2 assessment was not run: its own files do not match their approved hashes") ;;
        *)  REFUSE+=("the Section 2 assessment returned unexpected exit code '$code'") ;;
    esac
    if [ "$code" = 10 ]; then
        m=$(fact pre_module_state)
        [ "$m" = installed ] \
            || REFUSE+=("inconsistent: the assessment says REFRESH but the module state is '${m:-unknown}'")
        if [ "$(fact fp_valid)" != true ]; then
            REFUSE+=("the assessment printed no complete fingerprint - this build could not be recorded")
        elif [ "$(fact fp_uuid)" != "$EXPECTED_UUID" ]; then
            REFUSE+=("the fingerprint's uuid is '$(fact fp_uuid)', expected $EXPECTED_UUID")
        fi
    fi
    case "$(fact odoo_service)" in
        inactive|failed) ;;
        *) REFUSE+=("Odoo service is '$(fact odoo_service)' - stop it first (heavy work runs with Odoo stopped); this script never stops or starts Odoo") ;;
    esac
    [ "$(fact odoo_processes)" = 0 ] \
        || REFUSE+=("$(fact odoo_processes) Odoo process(es) still running from $ODOO_BIN")
    [ "$(fact odoo_bin_ok)" = true ] \
        || REFUSE+=("$ODOO_BIN is missing or not executable")
    if [ "$(fact conf_readable)" != true ]; then
        REFUSE+=("$ODOO_CONF is missing or unreadable")
        return
    fi
    case "$(fact conf_db_host)" in
        ""|False|false|127.0.0.1|localhost|/*) ;;
        *) REFUSE+=("$ODOO_CONF sends Odoo to database host '$(fact conf_db_host)' - not this server") ;;
    esac
    case "$(fact conf_db_port)" in
        ""|False|false|5432) ;;
        *) REFUSE+=("$ODOO_CONF sends Odoo to database port '$(fact conf_db_port)' - this server's cluster is on 5432") ;;
    esac
    [ "$(fact module_copies)" = 1 ] \
        || REFUSE+=("$(fact module_copies) copies of $MODULE on the active addons_path (${F[module_copy_paths]:-none}) - exactly one is required")
}

build_cmd() {    # the command, built once; shown from and run from this same array
    local key pins=()
    for key in "${DRIVER_KEYS[@]}"; do pins+=("$key=${PIN[$key]}"); done
    CMD=(sudo -u "$ODOO_USER" env
         "FD4_MODE=$TXN_MODE"
         "FD4_INJECT=$INJECT"
         "FD4_DIR=$HERE"
         "FD4_MODULE_DIR=$(fact module_dir)"
         "FD4_EXPECTED_DB=$DATABASE"
         "FD4_EXPECTED_UUID=$EXPECTED_UUID"
         "FD4_PRE_POSTMASTER_START=$(fact fp_postmaster_start)"
         "FD4_LOCK_TIMEOUT=$LOCK_TIMEOUT"
         "FD4_PINS=$(IFS=';'; printf '%s' "${pins[*]}")"
         "$ODOO_BIN" shell --config "$ODOO_CONF" -d "$DATABASE" --no-http "--logfile=$LOG")
}

show_cmd() {     # the command as run, with the eight driver pins abbreviated
    local word
    printf 'cd /tmp && '
    for word in "${CMD[@]}"; do
        case "$word" in
            FD4_PINS=*) printf 'FD4_PINS=<the %s driver pins above> ' "${#DRIVER_KEYS[@]}" ;;
            *) printf '%q ' "$word" ;;
        esac
    done
    printf '< %q' "$HERE/12a_refresh_transaction.py"
}

run_transaction() {   # THE ONLY WRITE PATH. Runs once; never retried.
    # Called inside `if`, where set -e does not apply: every step checks itself.
    if [ -n "$FACTS_FILE" ]; then          # test: a stand-in, the facts give its output
        TRANSACTION_EXECUTED=yes
        DRIVER_OUT=$FACTS_FILE
        return "${F[test_odoo_rc]:-0}"
    fi
    # A NEW directory only: mkdir fails if the name exists, so no existing
    # directory is ever re-owned or re-moded.
    mkdir -m 0750 "$RUN_DIR" || die "could not create $RUN_DIR - nothing was started"
    chown "$ODOO_USER:$ODOO_USER" "$RUN_DIR" || die "could not hand $RUN_DIR to $ODOO_USER - nothing was started"
    : > "$DRIVER_OUT" || die "cannot write $DRIVER_OUT - nothing was started"
    : > "$DRIVER_ERR" || die "cannot write $DRIVER_ERR - nothing was started"
    TRANSACTION_EXECUTED=yes               # from here on, odoo shell is running
    ( cd /tmp && "${CMD[@]}" < "$HERE/12a_refresh_transaction.py" ) \
        > "$DRIVER_OUT" 2> "$DRIVER_ERR"
}

parse_driver() {  # the FD4 lines -> D_*. Reads the driver output only.
    local file=$1
    D_OUTCOME=$(awk -F'|' '$1 == "FD4" && $2 == "outcome" {o = $0} END {print o}' "$file")
    D_ATTEMPTED=$(awk -F'|' '$1 == "FD4" && $2 == "commit" && $3 == "ATTEMPTED" {n++} END {print n + 0}' "$file")
    D_DONE=$(awk -F'|' '$1 == "FD4" && $2 == "commit" && $3 == "DONE" {n++} END {print n + 0}' "$file")
    D_STAMP=$(awk -F'|' '$1 == "FD4" && $2 == "stamp" {s = $3} END {print s}' "$file")
    D_ROWS=$(awk -F'|' '$1 == "FD4" && $2 == "rows" && $3 == "final" {r = $4 " " $5 " " $6 " " $7 " " $8} END {print r}' "$file")
    D_EXPECTED=$(awk -F'|' '$1 == "FD4" && $2 == "expected-failures" {e = $3} END {print e}' "$file")
    case "$D_OUTCOME" in
        "FD4|outcome|COMMITTED")              D_KIND=committed ;;
        "FD4|outcome|UNKNOWN"*)               D_KIND=unknown ;;
        "FD4|outcome|ROLLED_BACK|test|"*)     D_KIND=test ;;
        "FD4|outcome|ROLLED_BACK|gate|"*)     D_KIND=gate ;;
        "FD4|outcome|ROLLED_BACK|refused|"*)  D_KIND=refused ;;
        "FD4|outcome|ROLLED_BACK|error|"*)    D_KIND=error ;;
        "")                                   D_KIND=none ;;
        *)                                    D_KIND=other ;;
    esac
}

wants_fresh_read() {   # after these, a fresh connection must say what is committed
    case "$D_KIND" in committed|unknown) return 0 ;; esac
    [ "$D_ATTEMPTED" -gt 0 ] || [ "$D_DONE" -gt 0 ]
}

post_facts() {   # a FRESH connection, read-only: what is committed now
    local out
    layer_facts post soft
    if out=$(q_sql "$STAMP_SQL" 2>/dev/null); then
        F[post_stamp]=$out
        F[post_stamp_ok]=true
    else
        F[post_stamp_ok]=false
    fi
    if out=$(q "$HERE/06c_validate_cross_table.sql" 2>/dev/null); then
        F[post_06c_rows]=$(awk 'NF {n++} END {print n + 0}' <<<"$out")
        F[post_06c_pass]=$(awk -F'|' '$5 == "PASS" {n++} END {print n + 0}' <<<"$out")
    else
        F[post_06c_rows]=0
        F[post_06c_pass]=0
    fi
}

test_mode() { [ "$TXN_MODE" != live ] || [ "$INJECT" != none ]; }

decide_post() {  # facts + driver lines -> CODE, REASONS, COMMITTED, NEED_VACUUM, FRESH
    local bad=() i t want got
    if test_mode && { [ "$D_KIND" = committed ] || [ "$D_ATTEMPTED" -gt 0 ] || [ "$D_DONE" -gt 0 ]; }; then
        CODE=43 COMMITTED=unknown FRESH=yes
        REASONS=("a TEST run reported a commit attempt - impossible by design; check the layer (06b, 06c) before anything else")
        return
    fi
    case "$D_KIND" in
        test)
            COMMITTED=no
            if ! test_mode; then
                CODE=41 REASONS=("the driver ran as a test although --live was requested - nothing was committed")
            elif [ "$ODOO_RC" != 0 ]; then
                CODE=41 REASONS=("every check passed and the transaction was rolled back, but odoo shell exited $ODOO_RC - read driver.err before relying on this run")
            else
                CODE=0 REASONS=("every check passed; the transaction was rolled back as a test always is - nothing was committed")
                if [ "$INJECT" = before-build ]; then
                    REASONS+=("L-A: the made-up rows were removed by the clear and did not come back with the build")
                fi
            fi ;;
        gate)
            CODE=42 COMMITTED=no
            REASONS=("rolled back, previous data unchanged: ${D_OUTCOME#FD4|outcome|ROLLED_BACK|gate|}")
            if [ "$INJECT" = after-build ]; then
                REASONS+=("L-B expected failures: ${D_EXPECTED:-not reported}")
            fi
            if [ "$ODOO_RC" != 0 ]; then REASONS+=("odoo shell exited $ODOO_RC after reporting its outcome"); fi ;;
        refused|error)
            CODE=41 COMMITTED=no
            REASONS=("rolled back, previous data unchanged: ${D_OUTCOME#FD4|outcome|ROLLED_BACK|}") ;;
        none|other)
            if [ "$D_ATTEMPTED" -gt 0 ]; then
                CODE=43 COMMITTED=unknown FRESH=yes
                REASONS=("odoo shell ended after attempting the commit, without reporting its result (exit $ODOO_RC)")
            else
                CODE=41 COMMITTED=no
                REASONS=("odoo shell ended without an outcome (exit $ODOO_RC) and never attempted a commit - PostgreSQL discarded whatever it had started; read driver.err and odoo-shell.log")
            fi ;;
        unknown)
            CODE=43 COMMITTED=unknown FRESH=yes
            REASONS=("the commit raised an error: ${D_OUTCOME#FD4|outcome|UNKNOWN|}") ;;
        committed)
            COMMITTED=yes
            [ "$ODOO_RC" = 0 ] \
                || bad+=("odoo shell exited $ODOO_RC after reporting the commit")
            [ "$(fact post_postmaster_start)" = "$(fact fp_postmaster_start)" ] \
                || bad+=("cluster start time is now '$(fact post_postmaster_start)', it was '$(fact fp_postmaster_start)' at the pre-check")
            if [ "$(fact post_stamp_ok)" != true ] || [ -z "$D_STAMP" ] \
                    || [ "$(fact post_stamp)" != "$D_STAMP" ]; then
                bad+=("refresh time from a fresh connection is '$(fact post_stamp)', the transaction wrote '$D_STAMP'")
            fi
            [ "$(fact post_module_state)" = installed ] \
                || bad+=("module state is '$(fact post_module_state)', expected installed")
            read -r -a want <<<"$D_ROWS"
            if [ ${#want[@]} != 5 ]; then
                bad+=("the driver reported no final row counts")
            else
                for i in 0 1 2 3 4; do
                    t=${TABLES[$i]}
                    got=$(fact "post_rows:$t")
                    [ "$(fact "post_present:$t")" = true ] && [ "$got" = "${want[$i]}" ] \
                        || bad+=("$t: $got row(s) committed, the transaction reported ${want[$i]}")
                done
            fi
            [ "$(fact post_provisioned_by)" = orm ] \
                || bad+=("tables provisioned by '$(fact post_provisioned_by)', expected the ORM")
            [ "$(fact post_schema_money_bad)" = 0 ] && [ "$(fact post_schema_aging_bad)" = 0 ] \
                && [ -z "$(fact post_schema_index_missing)" ] && [ -z "$(fact post_schema_grain_missing)" ] \
                || bad+=("schema not clean: money_bad=$(fact post_schema_money_bad) aging_bad=$(fact post_schema_aging_bad) index_missing=$(fact post_schema_index_missing) grain_missing=$(fact post_schema_grain_missing)")
            [ "$(fact post_partner_idx)" = true ] \
                || bad+=("finance_dashboard_arap_partner_idx is missing after the commit")
            [ "$(fact post_06c_rows)" = 7 ] && [ "$(fact post_06c_pass)" = 7 ] \
                || bad+=("06c from a fresh connection: $(fact post_06c_pass)/$(fact post_06c_rows) PASS")
            if [ ${#bad[@]} -gt 0 ]; then
                CODE=43 FRESH=yes
                REASONS=("PostgreSQL confirmed the commit, but the fresh check does not agree:" "${bad[@]}")
            else
                CODE=0 NEED_VACUUM=yes
                REASONS=("committed, and confirmed from a fresh connection: same cluster start time, the refresh time and row counts the transaction reported, 06c 7/7, schema clean")
            fi ;;
    esac
}

fresh_state() {  # 43 only: which data a fresh connection sees now. Facts only.
    local now before
    now=$(fact post_stamp)
    before=$(fact pre_stamp)
    if [ "$(fact post_postmaster_start)" != "$(fact fp_postmaster_start)" ]; then
        REASONS+=("fresh connection: the cluster restarted since the pre-check (start time '$(fact fp_postmaster_start)' -> '$(fact post_postmaster_start)'); whatever is in place belongs to the restarted cluster - run the assessment")
    elif [ "$(fact post_stamp_ok)" != true ]; then
        REASONS+=("fresh connection: the refresh time could not be read - the tables may be missing; run the assessment")
    elif [ -n "$D_STAMP" ] && [ "$now" = "$D_STAMP" ]; then
        REASONS+=("fresh connection: the NEW data is in place (refresh time $now, written by this transaction)")
    elif [ "$now" = "$before" ]; then
        REASONS+=("fresh connection: NOT committed - the previous data is in place (refresh time unchanged: ${before:-none - the tables are as the install left them})")
    else
        REASONS+=("fresh connection: undetermined - refresh time is '$now' (before: '${before:-none}', this transaction: '${D_STAMP:-not reported}')")
    fi
    REASONS+=("no fingerprint is printed: the next assessment decides what to do")
}

do_vacuum() {    # after a VERIFIED commit only. Plain VACUUM (ANALYZE), never FULL.
    local args=() t
    if [ -n "$FACTS_FILE" ]; then return "${F[test_vacuum_rc]:-0}"; fi
    for t in "${VACUUM_TABLES[@]}"; do args+=(-c "VACUUM (ANALYZE) public.$t;"); done
    sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 \
        -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" "${args[@]}"
}

mode_text() {
    local text
    if [ -n "$FACTS_FILE" ]; then text=TEST; else text=LIVE; fi
    if [ "$DRY_RUN" = 1 ]; then text="$text, DRY RUN"; fi
    if [ "$LIVE" = 1 ]; then text="$text, REAL REFRESH (--live)"
    elif [ "$ROLLBACK_ONLY" = 1 ]; then text="$text, ROLLBACK-ONLY"
    else text="$text (pre-checks only)"; fi
    if [ "$INJECT" != none ]; then text="$text, TEST ROWS $INJECT"; fi
    printf '%s' "$text"
}

report() {
    local key ok=0 t rows=() word line
    for key in "${PIN_KEYS[@]}"; do if pin_ok "$key"; then ok=$((ok + 1)); fi; done
    for t in "${TABLES[@]}"; do rows+=("${t#finance_dashboard_}=$(fact "pre_rows:$t")"); done
    echo "=== Finance Dashboard - Section 4: refresh ==="
    echo "mode          : $(mode_text)"
    echo "files         : $ok/${#PIN_KEYS[@]} match their approved SHA-256"
    for key in "${PIN_KEYS[@]}"; do
        if ! pin_ok "$key"; then echo "    MISMATCH  $key  found=$(fact "file_sha:$key")"; fi
    done
    echo "assessment    : exit $(fact pre_assess_code) - $(fact pre_assess_verdict)"
    echo "fingerprint   : postmaster_start=$(fact fp_postmaster_start) (kept from this pre-check)"
    echo "module        : $(fact pre_module_state)  pending=$(fact pre_pending_modules)"
    echo "odoo          : service=$(fact odoo_service) processes=$(fact odoo_processes) binary_ok=$(fact odoo_bin_ok)"
    echo "config        : $ODOO_CONF readable=$(fact conf_readable) db_host=$(fact conf_db_host) db_port=$(fact conf_db_port)"
    echo "module copy   : $(fact module_copies) ($(fact module_dir))"
    echo "layer before  : ${rows[*]}  refresh_time=$(fact pre_stamp)"
    if [ ${#CMD[@]} -gt 0 ]; then echo "command       : $(show_cmd)"; fi
    echo "transaction   : executed=$TRANSACTION_EXECUTED odoo_shell_exit=${ODOO_RC:-not run}"
    if [ "$TRANSACTION_EXECUTED" = yes ]; then
        while IFS= read -r line; do
            case "$line" in FD4\|*) echo "    ${line#FD4|}" ;; esac
        done < "$DRIVER_OUT"
        if [ "$FRESH_READ" = yes ]; then
            rows=()
            for t in "${TABLES[@]}"; do rows+=("${t#finance_dashboard_}=$(fact "post_rows:$t")"); done
            echo "fresh check   : ${rows[*]}"
            echo "                refresh_time=$(fact post_stamp) postmaster_start=$(fact post_postmaster_start) 06c=$(fact post_06c_pass)/$(fact post_06c_rows) module=$(fact post_module_state) partner_idx=$(fact post_partner_idx)"
        fi
        echo "vacuum        : executed=$VACUUM_EXECUTED exit=${VACUUM_RC:-not run}"
        if [ -z "$FACTS_FILE" ]; then
            echo "logs          : $RUN_DIR  (odoo-owned directory: read with sudo)"
        fi
    fi
    case "$CODE" in
        0)  if [ "$DRY_RUN" = 1 ]; then word="PRE-CHECKS PASSED - dry run, nothing was started"
            elif test_mode; then word="ROLLBACK-ONLY TEST PASSED - nothing was committed"
            else word="REFRESHED AND VERIFIED"; fi ;;
        40) word="REFUSED - nothing was started" ;;
        41) word="TECHNICAL FAILURE - rolled back" ;;
        42) word="CHECKS FAILED - rolled back" ;;
        43) word="COMMIT NOT CONFIRMED" ;;
        44) word="COMMITTED AND VERIFIED - VACUUM FAILED" ;;
        *)  word="UNEXPECTED" ;;
    esac
    echo "------------------------------------------------------------"
    echo "result        : $word"
    for line in "${REASONS[@]}"; do echo "  - $line"; done
    echo "TRANSACTION_EXECUTED=$TRANSACTION_EXECUTED"
    echo "TRANSACTION_COMMITTED=$COMMITTED"
    echo "VACUUM_EXECUTED=$VACUUM_EXECUTED"
    if [ "$DRY_RUN" = 0 ] && ! test_mode && [ "$COMMITTED" = yes ] \
            && { [ "$CODE" = 0 ] || [ "$CODE" = 44 ]; }; then
        echo "RECORD_FINGERPRINT_JSON=$(fact pre_fingerprint_json)"
    fi
    echo "RESULT=$CODE"
}

# ---- main --------------------------------------------------------------------
if [ -n "$FACTS_FILE" ]; then
    load < "$FACTS_FILE"
else
    env_facts
    module_dir_fact
    file_facts
    ASSESS_OK=yes
    for key in "${ASSESS_KEYS[@]}"; do pin_ok "$key" || ASSESS_OK=no; done
    if [ "$ASSESS_OK" = yes ]; then
        assess
        case "$(fact pre_assess_code)" in  # only verdicts that prove the target was checked
            0|10|11|21|22) layer_facts pre ;;
            *) ;;                         # never query a database the assessment did not confirm
        esac
        if [ "$(fact pre_assess_code)" = 10 ]; then
            F[pre_stamp]=$(q_sql "$STAMP_SQL") || die "could not read the refresh time (psql message above)"
        fi
    else
        F[pre_assess_code]=not-run
    fi
fi
module_dir_fact     # also in a test, so the path derivation itself is tested
parse_fingerprint

decide_pre
if [ ${#REFUSE[@]} -gt 0 ]; then
    CODE=40 REASONS=("${REFUSE[@]}")
    report
    exit 40
fi
build_cmd
if [ "$DRY_RUN" = 1 ]; then
    CODE=0 REASONS=("every pre-check passed; the command above was NOT run")
    report
    exit 0
fi

if run_transaction; then ODOO_RC=0; else ODOO_RC=$?; fi
parse_driver "$DRIVER_OUT"
if wants_fresh_read; then
    FRESH_READ=yes
    if [ -z "$FACTS_FILE" ]; then post_facts; fi   # in a test the facts hold them
fi
decide_post
if [ "$NEED_VACUUM" = yes ]; then
    VACUUM_EXECUTED=yes
    if do_vacuum; then VACUUM_RC=0; else VACUUM_RC=$?; fi
    if [ "$VACUUM_RC" != 0 ]; then
        CODE=44
        REASONS+=("VACUUM (ANALYZE) failed (exit $VACUUM_RC). The committed data is verified and stays; run VACUUM (ANALYZE) on ${VACUUM_TABLES[*]} by hand")
    fi
fi
if [ "$FRESH" = yes ]; then fresh_state; fi

if [ -z "$FACTS_FILE" ] && [ -d "$RUN_DIR" ] && report > "$RESULT_FILE" 2>&1; then
    cat "$RESULT_FILE"
else
    report
fi
exit "$CODE"
