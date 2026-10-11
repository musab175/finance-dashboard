#!/usr/bin/env bash
# =============================================================================
# 10_assess.sh - Finance Dashboard bootstrap, SECTION 2: ASSESS. 2026-10-11.
#
# READ-ONLY. Answers four questions and prints ONE verdict. It changes nothing:
# it never starts or stops a service, never runs Odoo, writes no file and no
# database row. Every psql session is opened with default_transaction_read_only
# = on, so PostgreSQL itself rejects any write, and the script refuses to go on
# if that guard is not in force.
#
#   1. Right database?        hostname, a Unix-socket connection proven from the
#                             server side, database name, data directory, uuid
#   2. Changed since the      pg_postmaster_start_time(), the highest ledger line
#      last good run?         id and the ledger's insert/update/delete counts,
#                             against state.json's last success
#   3. Module state?          odoo17_finance_dashboard, and ANY module marked
#                             to install / to upgrade / to remove
#   4. Reporting layer?       the five tables, their schema, row counts, and the
#                             06c cross-table checks
#
# VERDICTS                    EXIT
#   NOTHING TO DO               0  installed; layer complete, correct, consistent,
#                                  and the fingerprint matches the last successful
#                                  build (see THE FINGERPRINT)
#   REFRESH                    10  installed; layer structurally sound but empty,
#                                  inconsistent, or the fingerprint does not match
#   INSTALL + REFRESH          11  module absent or uninstalled, no reporting
#                                  tables - the normal state after a replacement
#   STOP: wrong target         20  not this server, not the socket, not this database
#   STOP: pending modules      21  a module operation is pending, or this module is
#                                  in a state the bootstrap does not handle
#   STOP: layer anomaly        22  something a refresh cannot fix - investigate
#   ERROR                       2  the assessment itself could not be completed
#
# CONNECTION: the local cluster's Unix socket only (/var/run/postgresql, socket
# file .s.PGSQL.5432). No TCP host appears anywhere in this script, so it cannot
# reach another server. The server side confirms it: inet_server_addr() IS NULL.
#
# USAGE
#   sudo bash 10_assess.sh                       assess this server
#   sudo bash 10_assess.sh --state-file PATH     read another state file
#   sudo bash 10_assess.sh --database NAME       (test) another database on the
#                                                same local cluster
#   bash 10_assess.sh --facts FILE               (test) decide from a facts file:
#                                                no database, no sudo
#
# THE FINGERPRINT (approved 2026-10-01; ledger statistics added 2026-10-11)
#   uuid                  must equal the pinned value and the state file's,
#                         otherwise STOP: wrong target
#   postmaster_start      changes on every restart, including a replacement
#   max_aml_id            changes when a ledger line is added
#   aml_n_tup_ins/upd/del PostgreSQL's running insert, update and delete counts
#                         for account_move_line (pg_stat_user_tables). They
#                         change when an EXISTING line is edited, e.g. a draft
#                         entry posted, which adds no new id.
# Any difference from state.json's last success means REFRESH.
#
# LIMITS OF THE LEDGER STATISTICS. They are change INDICATORS, not an audit trail:
# they say THAT rows changed, never which, when, or whether it mattered.
#   * Comparable only within one PostgreSQL uptime - postmaster_start pins that.
#   * pg_stat_reset() resets them. Counts that go DOWN still differ: REFRESH.
#   * They also count rolled-back writes and columns the reports never read, so
#     they can ask for a refresh that changes nothing. That is the safe side.
#   * They need track_counts = on. Checked: if off, never NOTHING TO DO.
#   * A committed write reaches them only after a delay - normally within
#     seconds, but with NO guaranteed upper bound: the connection that wrote it
#     publishes its counts when it next goes idle. The assessment can therefore
#     miss a recent write. A later run sees it.
#   * TRUNCATE is not counted. Odoo never truncates the ledger, and max_aml_id
#     would change anyway.
#
# RULE FOR SECTION 4 (the refresh): read the whole fingerprint in a separate
# statement just BEFORE the refresh transaction takes its snapshot, and record it
# in state.json only after the gate passes and COMMIT succeeds. A ledger change
# between that read and the snapshot then shows up later as a difference - a
# harmless extra REFRESH - and a change after the snapshot can never be mistaken
# for one the layer already contains. Reading it INSIDE the refresh transaction
# would not be safe: the statistics lag could count a write the snapshot missed.
#
# STATE FILE - written by a later section, only READ here. The part used:
#   {"last_success": {"fingerprint": {"uuid": "...", "postmaster_start": "...",
#     "max_aml_id": "...", "aml_n_tup_ins": "...", "aml_n_tup_upd": "...",
#     "aml_n_tup_del": "..."}}}
# Missing -> REFRESH. Not a state record, or a component missing -> REFRESH.
# Exists but unreadable -> ERROR.
# =============================================================================
set -euo pipefail

EXPECTED_HOSTNAME=gft-odoo-report
EXPECTED_DATABASE=gftuae
EXPECTED_DATA_DIRECTORY=/mnt/data/postgres/16/main
EXPECTED_UUID=629148b0-9f15-11ee-bf49-2569bf801689
SOCKET_DIR=/var/run/postgresql
SOCKET_PORT=5432
MODULE=odoo17_finance_dashboard
STATE_FILE=/var/lib/fd-bootstrap/state.json
TABLES=(finance_dashboard_daily finance_dashboard_arap_daily
        finance_dashboard_aging_daily finance_dashboard_expense_daily
        finance_dashboard_coverage)

# Compared with state.json's last success. uuid is checked separately (STOP).
FP_KEYS=(postmaster_start max_aml_id aml_n_tup_ins aml_n_tup_upd aml_n_tup_del)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATABASE=$EXPECTED_DATABASE
FACTS_FILE=

while [ $# -gt 0 ]; do
    case "$1" in
        --facts)      FACTS_FILE=${2:?--facts needs a file};      shift 2 ;;
        --state-file) STATE_FILE=${2:?--state-file needs a path}; shift 2 ;;
        --database)   DATABASE=${2:?--database needs a name};     shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

declare -A F=()
fact() { printf '%s' "${F[$1]:-}"; }

load() {    # key|value lines on stdin -> F. A later line overrides an earlier one.
    local k v
    while IFS='|' read -r k v; do
        if [ -n "$k" ]; then F["$k"]=$v; fi
    done
}

die() {     # the assessment itself failed
    echo "ASSESSMENT ERROR: $*" >&2
    echo "VERDICT=ERROR"
    exit 2
}

q() {       # one read-only SQL file through the local socket -> key|value lines
    sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on' \
        psql -X -At -F '|' -v ON_ERROR_STOP=1 \
             -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" -f "$1"
}

n_present() {
    local n=0 t
    for t in "${TABLES[@]}"; do
        if [ "$(fact "present:$t")" = true ]; then n=$((n + 1)); fi
    done
    echo "$n"
}

read_state() {
    local out
    out=$(python3 - "$STATE_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
except FileNotFoundError:
    print("state_present|false"); sys.exit(0)
except PermissionError:
    print("state_present|unreadable"); sys.exit(0)
except ValueError:
    print("state_present|invalid"); sys.exit(0)
last = doc.get("last_success") if isinstance(doc, dict) else None
fp = last.get("fingerprint") if isinstance(last, dict) else None
if not isinstance(fp, dict) or not fp:
    print("state_present|invalid"); sys.exit(0)
print("state_present|true")
for key in ("uuid", "postmaster_start", "max_aml_id",
            "aml_n_tup_ins", "aml_n_tup_upd", "aml_n_tup_del"):
    value = fp.get(key)
    print("state_" + key + "|" + ("" if value is None else str(value)))
PY
    ) || die "python3 could not read the state file $STATE_FILE"
    load <<<"$out"
}

fp_changes() {  # one line per fingerprint component that differs from state.json
    local k
    for k in "${FP_KEYS[@]}"; do
        if [ "$(fact "state_$k")" != "$(fact "$k")" ]; then
            printf '%s %s -> %s\n' "$k" "$(fact "state_$k")" "$(fact "$k")"
        fi
    done
}

collect() {
    local out
    F[hostname]=$(hostname)
    out=$(q "$HERE/10a_assess_target.sql") || die "10a_assess_target.sql failed (psql message above)"
    load <<<"$out"
    [ "$(fact read_only)" = on ] || die "read-only session guard is not in force"

    # Query further ONLY a local-socket connection to the expected Odoo database.
    if [ "$(fact socket)" = true ] && [ "$(fact odoo_tables)" = true ] \
       && [ "$(fact database)" = "$EXPECTED_DATABASE" ]; then
        out=$(q "$HERE/10b_assess_facts.sql") || die "10b_assess_facts.sql failed (psql message above)"
        load <<<"$out"
        if [ "$(n_present)" = 5 ]; then
            out=$(q "$HERE/06c_validate_cross_table.sql") || die "06c_validate_cross_table.sql failed (psql message above)"
            # No pipelines here: under pipefail a reader that exits early could abort.
            F[gate_06c_rows]=$(awk 'NF {n++} END {print n+0}' <<<"$out")
            F[gate_06c_pass]=$(awk -F'|' '$5 == "PASS" {n++} END {print n+0}' <<<"$out")
            F[gate_06c_fail]=$(awk -F'|' 'NF && $5 != "PASS" {printf "%s%s", sep, $1; sep=","} END {print ""}' <<<"$out")
        fi
    fi
    read_state
}

decide() {  # facts in F -> VERDICT, CODE, REASONS. Reads nothing else.
    local t n m=$(fact module_state)
    local -a target=() pending=() anomaly=() refresh=() empty=()
    VERDICT= CODE= REASONS=()

    # ---- 0. the assessment's own preconditions -------------------------------
    if [ "$(fact read_only)" != on ]; then
        VERDICT=ERROR CODE=2 REASONS=("read-only session guard is not in force"); return
    fi
    if [ "$(fact state_present)" = unreadable ]; then
        VERDICT=ERROR CODE=2 REASONS=("state file $STATE_FILE exists but cannot be read - run with sudo"); return
    fi

    # ---- 1. right target? ----------------------------------------------------
    [ "$(fact hostname)" = "$EXPECTED_HOSTNAME" ] \
        || target+=("hostname is '$(fact hostname)', expected $EXPECTED_HOSTNAME")
    [ "$(fact socket)" = true ] \
        || target+=("connection did not arrive through the local Unix socket")
    [ "$(fact database)" = "$EXPECTED_DATABASE" ] \
        || target+=("database is '$(fact database)', expected $EXPECTED_DATABASE")
    [ "$(fact data_directory)" = "$EXPECTED_DATA_DIRECTORY" ] \
        || target+=("data directory is '$(fact data_directory)', expected $EXPECTED_DATA_DIRECTORY")
    [ "$(fact odoo_tables)" = true ] \
        || target+=("not an Odoo database (ir_config_parameter, ir_module_module or account_move_line missing)")
    if [ "$(fact odoo_tables)" = true ] && [ "$(fact database)" = "$EXPECTED_DATABASE" ]; then
        [ "$(fact uuid)" = "$EXPECTED_UUID" ] \
            || target+=("database.uuid is '$(fact uuid)', expected $EXPECTED_UUID")
        if [ "$(fact state_present)" = true ] && [ "$(fact state_uuid)" != "$(fact uuid)" ]; then
            target+=("state file records uuid '$(fact state_uuid)', database has '$(fact uuid)'")
        fi
    fi
    if [ ${#target[@]} -gt 0 ]; then
        VERDICT="STOP: wrong target" CODE=20 REASONS=("${target[@]}"); return
    fi

    # ---- 2. module state and pending operations ------------------------------
    [ -z "$(fact pending_modules)" ] \
        || pending+=("pending module operations: $(fact pending_modules)")
    case "$m" in
        absent|uninstalled|installed) ;;
        "to install"|"to upgrade"|"to remove") ;;   # already reported as pending
        *) pending+=("$MODULE is '$m' - not a state the bootstrap handles") ;;
    esac
    if [ ${#pending[@]} -gt 0 ]; then
        VERDICT="STOP: pending modules" CODE=21 REASONS=("${pending[@]}"); return
    fi

    # ---- 3. reporting layer: structure ---------------------------------------
    n=$(n_present)
    if [ "$n" -gt 0 ] && [ "$n" -lt 5 ]; then
        local missing=()
        for t in "${TABLES[@]}"; do
            if [ "$(fact "present:$t")" != true ]; then missing+=("$t"); fi
        done
        anomaly+=("incomplete layer: $n of 5 tables (missing: ${missing[*]})")
    elif [ "$n" = 0 ] && [ "$m" = installed ]; then
        anomaly+=("module installed but none of its five tables exist - dropped outside Odoo; classify before any -u")
    elif [ "$n" = 5 ] && [ "$m" != installed ]; then
        anomaly+=("all five tables exist but the module is '$m' - provisioned outside Odoo; installing over them is not assumed safe")
    elif [ "$n" = 5 ]; then
        [ "$(fact provisioned_by)" = orm ] \
            || anomaly+=("tables provisioned by the '$(fact provisioned_by)' path - not interchangeable with the ORM layer")
        [ "$(fact schema_money_bad)" = 0 ] \
            || anomaly+=("$(fact schema_money_bad) money column(s) missing or not numeric(18,2)")
        [ "$(fact schema_aging_bad)" = 0 ] \
            || anomaly+=("$(fact schema_aging_bad) aging amount column(s) missing or not unconstrained numeric")
        [ -z "$(fact schema_index_missing)" ] \
            || anomaly+=("provisioning index(es) missing: $(fact schema_index_missing)")
        [ -z "$(fact schema_grain_missing)" ] \
            || anomaly+=("no unique index on the grain of: $(fact schema_grain_missing)")
    fi
    if [ ${#anomaly[@]} -gt 0 ]; then
        VERDICT="STOP: layer anomaly" CODE=22 REASONS=("${anomaly[@]}"); return
    fi

    # ---- 4. nothing built yet: install, then refresh -------------------------
    if [ "$n" = 0 ]; then
        VERDICT="INSTALL + REFRESH" CODE=11
        REASONS=("module is '$m' and no reporting table exists")
        return
    fi

    # ---- 5. installed and structurally sound: data present, fingerprint match? -
    for t in "${TABLES[@]}"; do
        if [ "$(fact "rows:$t")" = 0 ]; then empty+=("$t"); fi
    done
    if [ ${#empty[@]} -gt 0 ]; then
        refresh+=("empty table(s): ${empty[*]}")
    else
        [ "$(fact partner_idx)" = true ] \
            || refresh+=("finance_dashboard_arap_partner_idx missing - 04 recreates it")
        if [ "$(fact gate_06c_rows)" != 7 ] || [ "$(fact gate_06c_pass)" != 7 ]; then
            refresh+=("06c cross-table checks: $(fact gate_06c_pass) of $(fact gate_06c_rows) PASS (failing: $(fact gate_06c_fail))")
        fi
    fi
    [ "$(fact track_counts)" = on ] \
        || refresh+=("track_counts is '$(fact track_counts)' - ledger row changes cannot be detected")
    case "$(fact state_present)" in
        false)   refresh+=("no state record at $STATE_FILE - cannot prove which data the layer was built from") ;;
        invalid) refresh+=("$STATE_FILE is not a readable state record - cannot prove which data the layer was built from") ;;
        true)
            local line
            while IFS= read -r line; do
                if [ -n "$line" ]; then refresh+=("changed since the last successful build: $line"); fi
            done <<<"$(fp_changes)" ;;
        *)       refresh+=("state file status '$(fact state_present)' not understood") ;;
    esac
    if [ ${#refresh[@]} -gt 0 ]; then
        VERDICT=REFRESH CODE=10 REASONS=("${refresh[@]}"); return
    fi
    VERDICT="NOTHING TO DO" CODE=0
    REASONS=("module installed; layer complete, correct and consistent; no restart, no new ledger line and no recorded ledger row change since the last successful build")
}

report() {
    local t rows=()
    for t in "${TABLES[@]}"; do rows+=("${t#finance_dashboard_}=$(fact "rows:$t")"); done
    echo "=== Finance Dashboard - Section 2 assessment (read-only) ==="
    echo "host        : $(fact hostname)"
    echo "connection  : socket=$(fact socket) database=$(fact database) port=$(fact port) read_only=$(fact read_only)"
    echo "cluster     : $(fact data_directory)  (PostgreSQL $(fact server_version))"
    echo "uuid        : $(fact uuid)"
    echo "fingerprint : postmaster_start=$(fact postmaster_start) max_aml_id=$(fact max_aml_id)"
    echo "ledger stats: account_move_line ins=$(fact aml_n_tup_ins) upd=$(fact aml_n_tup_upd) del=$(fact aml_n_tup_del)  track_counts=$(fact track_counts)"
    echo "audit only  : pg_database_oid=$(fact pg_database_oid) system_identifier=$(fact system_identifier) stats_reset=$(fact stats_reset)"
    echo "state file  : $STATE_FILE -> $(fact state_present)"
    local changes
    changes=$(fp_changes)
    if [ "$(fact state_present)" != true ]; then
        echo "since last  : no record of a successful run to compare with"
    elif [ -z "$changes" ]; then
        echo "since last  : same data (restart marker, max aml id and ledger counts unchanged)"
    else
        echo "since last  : DIFFERENT data"
        while IFS= read -r t; do echo "                $t"; done <<<"$changes"
    fi
    echo "module      : $MODULE=$(fact module_state)  pending=$(fact pending_modules)"
    echo "layer       : $(n_present)/5 tables  provisioned_by=$(fact provisioned_by)"
    echo "schema      : money_bad=$(fact schema_money_bad) aging_bad=$(fact schema_aging_bad) index_missing=$(fact schema_index_missing) grain_missing=$(fact schema_grain_missing) partner_idx=$(fact partner_idx)"
    echo "rows        : ${rows[*]}"
    echo "06c         : $(fact gate_06c_pass)/$(fact gate_06c_rows) PASS"
    echo "last refresh: $(fact coverage_last_refresh)"
    echo "------------------------------------------------------------"
    echo "verdict     : $VERDICT"
    for t in "${REASONS[@]}"; do echo "  - $t"; done
    if [ -n "$(fact uuid)" ] && [ -n "$(fact postmaster_start)" ] && [ -n "$(fact max_aml_id)" ]; then
        echo "FINGERPRINT_JSON=$(python3 -c 'import json, sys; keys = ("uuid", "postmaster_start", "max_aml_id", "aml_n_tup_ins", "aml_n_tup_upd", "aml_n_tup_del"); print(json.dumps(dict(zip(keys, sys.argv[1:]))))' \
            "$(fact uuid)" "$(fact postmaster_start)" "$(fact max_aml_id)" \
            "$(fact aml_n_tup_ins)" "$(fact aml_n_tup_upd)" "$(fact aml_n_tup_del)")"
    fi
    echo "VERDICT=$VERDICT"
}

if [ -n "$FACTS_FILE" ]; then
    load < "$FACTS_FILE"
else
    collect
fi
decide
report
exit "$CODE"
