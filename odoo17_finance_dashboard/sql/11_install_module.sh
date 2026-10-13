#!/usr/bin/env bash
# =============================================================================
# 11_install_module.sh - Finance Dashboard bootstrap, SECTION 3: INSTALL. 2026-10-12.
#
# Installs odoo17_finance_dashboard ONLY when every pre-check passes, then proves
# the install worked. Nothing else: no refresh (Section 4), no upgrade, no retry,
# no recovery, and it never starts or stops Odoo - the operator (later the
# Section 6 wrapper) stops Odoo before and starts it after.
#
#   1. Pre-checks, read-only    a fresh Section 2 assessment says exactly
#                               INSTALL + REFRESH; the module state in
#                               ir_module_module is absent or uninstalled; the
#                               Odoo service is stopped and no Odoo process runs;
#                               exactly ONE copy of the module on the addons_path
#                               of the active config; Odoo's own database
#                               connection in that config is local
#   2. Install, the one write   one `odoo -i` from /tmp, logging to its own file,
#                               keeping odoo's real exit code (no pipe)
#   3. Post-checks, read-only   exit code 0; state 'installed'; all five tables
#                               present, ORM-built, clean layout, EMPTY; and a
#                               fresh Section 2 assessment says REFRESH
#
# EXIT CODES
#   0   installed and verified - or, with --dry-run, every pre-check passed
#   30  odoo's install command exited non-zero
#   31  odoo exited 0 but the module is not installed
#   32  installed, but tables, layout or the follow-up assessment are wrong
#   33  a pre-check refused - NOTHING was run (includes: already installed)
#   2   this script itself failed
# Any other exit code (1, 127, 141 ...) is an unexpected abort: treat it as an
# error. Every non-zero exit prints its reasons.
#
# NEVER: -u, a second install of an installed module, resetting or clearing a
# module state, automatic retry, automatic recovery, a refresh.
#
# The config file holds the database password. This script reads only db_host,
# db_port and addons_path from it, and never prints anything else.
#
# LOGS: each real run creates a NEW directory /tmp/fd_section3_install_<UTC time>
# (it refuses if that name exists) and gives only that directory to the odoo
# user, mode 0750. Reading the logs therefore needs sudo.
#
# USAGE
#   sudo bash 11_install_module.sh --dry-run    pre-checks, print the command, stop
#   sudo bash 11_install_module.sh              pre-checks, install, post-checks
#   bash 11_install_module.sh --facts FILE      (test) made-up facts and a stand-in
#        [--dry-run]                            for the install; no Odoo, no sudo
#
# Same directory must hold: 10_assess.sh, 10a_assess_target.sql,
# 10b_assess_facts.sql and 06c_validate_cross_table.sql (used by 10_assess.sh).
# =============================================================================
set -euo pipefail

ODOO_BIN=/mnt/data/app/bin/odoo
ODOO_CONF=/mnt/data/app/odoo.conf
ODOO_USER=odoo
ODOO_SERVICE=odoo
DATABASE=gftuae
MODULE=odoo17_finance_dashboard
SOCKET_DIR=/var/run/postgresql
SOCKET_PORT=5432
TABLES=(finance_dashboard_daily finance_dashboard_arap_daily
        finance_dashboard_aging_daily finance_dashboard_expense_daily
        finance_dashboard_coverage)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
FACTS_FILE=

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --facts)   FACTS_FILE=${2:?--facts needs a file};  shift 2 ;;
        *) echo "unknown argument: $1" >&2; echo "RESULT=2"; exit 2 ;;
    esac
done

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="/tmp/fd_section3_install_$STAMP"   # created new for each real run
LOG="$RUN_DIR/odoo-install.log"
CONSOLE="$RUN_DIR/console.log"
# THE install command - built once; printed and executed from this same array.
CMD=(sudo -u "$ODOO_USER" "$ODOO_BIN" --config "$ODOO_CONF" -d "$DATABASE"
     -i "$MODULE" --no-http --stop-after-init "--logfile=$LOG")
INSTALL_EXECUTED=no
RC=
CODE=
REFUSE=()
REASONS=()
declare -A F=()
fact() { printf '%s' "${F[$1]:-}"; }

load() {    # key|value lines on stdin -> F. A later line overrides an earlier one.
    local k v
    while IFS='|' read -r k v; do
        if [ -n "$k" ]; then F["$k"]=$v; fi
    done
}

die() {
    echo "SECTION 3 ERROR: $*" >&2
    echo "INSTALL_EXECUTED=$INSTALL_EXECUTED"
    echo "RESULT=2"
    exit 2
}

q() {       # one read-only SQL file through the local socket -> key|value lines
    sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on' \
        psql -X -At -F '|' -v ON_ERROR_STOP=1 \
             -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" -f "$1"
}

assess() {  # $1 = pre|post : run Section 2 afresh, keep its exit code and verdict
    local out code=0
    out=$(bash "$HERE/10_assess.sh" 2>&1) || code=$?
    F["$1_assess_code"]=$code
    F["$1_assess_verdict"]=$(awk -F= '/^VERDICT=/ {v = $2} END {print v}' <<<"$out")
}

layer_facts() {  # $1 = pre|post, $2 = soft : module state + layer facts
    local out k v
    if ! out=$(q "$HERE/10b_assess_facts.sql"); then
        if [ "${2:-}" = soft ]; then   # after a failed install: record, never abort
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

decide_pre() {   # facts -> REFUSE[]. Reads nothing else.
    local code m
    code=$(fact pre_assess_code)
    case "$code" in
        11) ;;
        0|10) REFUSE+=("already installed: the assessment says '$(fact pre_assess_verdict)' - no installation attempted") ;;
        20)   REFUSE+=("the assessment says STOP: wrong target - not the expected reporting environment") ;;
        21)   REFUSE+=("the assessment says STOP: pending modules - a pending operation or an unexpected module state; investigate manually") ;;
        22)   REFUSE+=("the assessment says STOP: layer anomaly - investigate before any install") ;;
        2)    REFUSE+=("the Section 2 assessment did not complete - the environment cannot be confirmed") ;;
        *)    REFUSE+=("the Section 2 assessment returned unexpected exit code '$code'") ;;
    esac
    m=$(fact pre_module_state)
    case "$m" in
        absent|uninstalled) ;;
        installed) REFUSE+=("module state is 'installed' - it will not be installed again") ;;
        "to install"|"to upgrade"|"to remove")
                   REFUSE+=("module state is '$m' - an interrupted or pending operation; manual investigation required, no automatic recovery") ;;
        "")        REFUSE+=("module state could not be determined") ;;
        *)         REFUSE+=("module state is '$m' - not a state this script handles") ;;
    esac
    if [ "$code" = 11 ] && [ "$m" != absent ] && [ "$m" != uninstalled ]; then
        REFUSE+=("inconsistent: the assessment says INSTALL + REFRESH but the module state is '$m'")
    fi
    case "$(fact odoo_service)" in
        inactive|failed) ;;
        *) REFUSE+=("Odoo service is '$(fact odoo_service)' - stop it first; this script never stops or starts Odoo") ;;
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

install_cmd() {  # the exact command, printed from the same array do_install runs
    printf 'cd /tmp && '
    printf '%q ' "${CMD[@]}"
}

do_install() {   # THE ONLY WRITE. Runs once; never retried.
    # Called inside `if`, where set -e does not apply: every step checks itself.
    if [ -n "$FACTS_FILE" ]; then          # test: a stand-in, the facts say how it went
        INSTALL_EXECUTED=yes
        return "$(fact test_install_rc)"
    fi
    # A NEW directory only: mkdir fails if the name exists, so no existing
    # directory (such as /tmp itself) is ever re-owned or re-moded.
    mkdir -m 0750 "$RUN_DIR" || die "could not create $RUN_DIR - nothing was installed"
    chown "$ODOO_USER:$ODOO_USER" "$RUN_DIR" || die "could not hand $RUN_DIR to $ODOO_USER - nothing was installed"
    : > "$CONSOLE" || die "cannot write $CONSOLE - nothing was installed"
    INSTALL_EXECUTED=yes                   # from here on, odoo is running
    ( cd /tmp && "${CMD[@]}" ) >> "$CONSOLE" 2>&1
}

decide_post() {  # facts -> CODE, REASONS. Reads nothing else.
    local m t n=0 rows_bad=()
    local -a bad=()
    m=$(fact post_module_state)
    if [ "$RC" != 0 ]; then
        CODE=30
        REASONS=("odoo's install command exited $RC; the module state is now '${m:-unknown}' - read the log; manual investigation required, no automatic recovery")
        return
    fi
    if [ "$m" != installed ]; then
        CODE=31
        REASONS=("odoo exited 0 but the module state is '${m:-unknown}', not 'installed' - check the addons path and the log")
        return
    fi
    for t in "${TABLES[@]}"; do
        if [ "$(fact "post_present:$t")" = true ]; then
            n=$((n + 1))
            if [ "$(fact "post_rows:$t")" != 0 ]; then rows_bad+=("$t=$(fact "post_rows:$t")"); fi
        fi
    done
    [ "$n" = 5 ] || bad+=("$n of 5 tables exist")
    [ "$(fact post_provisioned_by)" = orm ] \
        || bad+=("tables provisioned by '$(fact post_provisioned_by)', expected the ORM")
    [ "$(fact post_schema_money_bad)" = 0 ] \
        || bad+=("$(fact post_schema_money_bad) money column(s) missing or not numeric(18,2)")
    [ "$(fact post_schema_aging_bad)" = 0 ] \
        || bad+=("$(fact post_schema_aging_bad) aging amount column(s) missing or not unconstrained numeric")
    [ -z "$(fact post_schema_index_missing)" ] \
        || bad+=("provisioning index(es) missing: $(fact post_schema_index_missing)")
    [ -z "$(fact post_schema_grain_missing)" ] \
        || bad+=("no unique index on the grain of: $(fact post_schema_grain_missing)")
    [ ${#rows_bad[@]} = 0 ] \
        || bad+=("tables are not empty after a fresh install: ${rows_bad[*]}")
    [ "$(fact post_assess_code)" = 10 ] \
        || bad+=("Section 2 now says '$(fact post_assess_verdict)' (exit $(fact post_assess_code)), expected REFRESH (exit 10)")
    if [ ${#bad[@]} -gt 0 ]; then
        CODE=32 REASONS=("${bad[@]}")
        return
    fi
    CODE=0
    REASONS=("installed and verified: state installed; 5 empty ORM tables with a clean layout; Section 2 says REFRESH")
}

report() {
    local t n=0 rows=() word
    echo "=== Finance Dashboard - Section 3: install $MODULE ==="
    echo "mode          : $MODE"
    echo "assessment    : exit $(fact pre_assess_code) - $(fact pre_assess_verdict)"
    echo "module state  : $(fact pre_module_state)  pending=$(fact pre_pending_modules)"
    echo "odoo          : service=$(fact odoo_service) processes=$(fact odoo_processes) binary_ok=$(fact odoo_bin_ok)"
    echo "config        : $ODOO_CONF readable=$(fact conf_readable) db_host=$(fact conf_db_host) db_port=$(fact conf_db_port)"
    echo "addons copies : $(fact module_copies) ($(fact module_copy_paths))"
    echo "command       : $(install_cmd)"
    echo "install       : executed=$INSTALL_EXECUTED exit=${RC:-not run}"
    if [ "$INSTALL_EXECUTED" = yes ]; then
        for t in "${TABLES[@]}"; do
            if [ "$(fact "post_present:$t")" = true ]; then n=$((n + 1)); fi
            rows+=("${t#finance_dashboard_}=$(fact "post_rows:$t")")
        done
        echo "post state    : $(fact post_module_state)"
        echo "post tables   : $n/5 provisioned_by=$(fact post_provisioned_by)  rows: ${rows[*]}"
        echo "post schema   : money_bad=$(fact post_schema_money_bad) aging_bad=$(fact post_schema_aging_bad) index_missing=$(fact post_schema_index_missing) grain_missing=$(fact post_schema_grain_missing)"
        echo "post assess   : exit $(fact post_assess_code) - $(fact post_assess_verdict)"
        if [ -z "$FACTS_FILE" ]; then
            echo "log           : $LOG  (odoo-owned directory: read with sudo)"
            echo "console       : $CONSOLE"
            if [ -r "$LOG" ]; then
                echo "log tail      :"
                while IFS= read -r t; do echo "    $t"; done < <(tail -n 8 "$LOG")
            fi
        fi
    fi
    case "$CODE" in
        0)  if [ "$DRY_RUN" = 1 ]; then word="PRE-CHECKS PASSED - dry run, nothing was executed"
            else word="INSTALLED AND VERIFIED"; fi ;;
        30) word="INSTALL COMMAND FAILED" ;;
        31) word="NOT INSTALLED" ;;
        32) word="INSTALLED, VERIFICATION FAILED" ;;
        33) word="REFUSED - nothing was run" ;;
        *)  word="UNEXPECTED" ;;
    esac
    echo "------------------------------------------------------------"
    echo "result        : $word"
    for t in "${REASONS[@]}"; do echo "  - $t"; done
    echo "INSTALL_EXECUTED=$INSTALL_EXECUTED"
    echo "RESULT=$CODE"
}

# ---- main --------------------------------------------------------------------
if [ -n "$FACTS_FILE" ]; then
    MODE=TEST
    load < "$FACTS_FILE"
else
    MODE=LIVE
    env_facts
    assess pre
    case "$(fact pre_assess_code)" in   # only verdicts that prove the target was checked
        0|10|11|21|22) layer_facts pre ;;
        *) ;;                          # never query a database the assessment did not confirm
    esac
fi
if [ "$DRY_RUN" = 1 ]; then MODE="$MODE, DRY RUN"; fi

decide_pre
if [ ${#REFUSE[@]} -gt 0 ]; then
    CODE=33 REASONS=("${REFUSE[@]}")
    report
    exit 33
fi
if [ "$DRY_RUN" = 1 ]; then
    CODE=0 REASONS=("every pre-check passed; the command above was NOT executed")
    report
    exit 0
fi

if do_install; then RC=0; else RC=$?; fi
if [ -z "$FACTS_FILE" ]; then
    if [ "$RC" = 0 ]; then layer_facts post; else layer_facts post soft; fi
    assess post
fi
decide_post
report
exit "$CODE"
