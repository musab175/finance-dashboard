#!/usr/bin/env bash
# =============================================================================
# 09_restore_reporting_test.sh - controlled tests for 09_restore_reporting.sh.
# 2026-10-15.
#
# MADE-UP FACTS, REAL FILES. No database, no Odoo, no sudo. Each case builds a
# scratch store - an fd_backup_<UTC> folder holding a stand-in archive and a
# record.json written the way 09a writes one, and a register line - and facts
# for what the server would report: owners and modes, the assessment, the
# current layer, the pre-restore backup, the driver's FD5 lines, the fresh read
# afterwards. Then it runs
#   bash 09_restore_reporting.sh --facts FILE --backup FOLDER <mode>
# The record, the register and the archive's SHA-256 are read FOR REAL.
#
# Every case checks SIX markers - the exit code, TRANSACTION_EXECUTED,
# TRANSACTION_COMMITTED, VACUUM_EXECUTED, whether PRE_RESTORE_BACKUP names a
# backup, whether RECORD_FINGERPRINT_JSON is printed - and that no work or data
# folder was left behind. "-" means the marker must be absent (argument errors
# stop before any marker is printed).
# The last cases use the 09a rehearsal's REAL archive, record and register: the
# archive is read with pg_restore, and the real driver's output is replayed.
# Cases marked [B] exist for --confirm-record (pending decision B).
# Usage:  bash 09_restore_reporting_test.sh [rehearsal store]   exit 0 only if every case passes
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/09_restore_reporting.sh"
REHEARSAL_STORE=${1:-}
WORK_T=$(mktemp -d)
trap 'rm -rf -- "${WORK_T:?}"' EXIT

UTC=20261015T081500Z
FOLDER=fd_backup_$UTC
ARCHIVE=fd_reporting_gftuae_$UTC.dump
START=2026-10-14T14:03:11.123456Z
FP='{"uuid": "629148b0-9f15-11ee-bf49-2569bf801689", "postmaster_start": "2026-10-14T14:03:11.123456Z", "max_aml_id": "30123456", "aml_n_tup_ins": "100", "aml_n_tup_upd": "7", "aml_n_tup_del": "0"}'
FP_LEDGER=${FP/30123456/30123457}
FP_RESTART=${FP/2026-10-14T14:03:11.123456Z/2026-10-15T14:03:09.000001Z}
FP_SHORT='{"uuid": "629148b0-9f15-11ee-bf49-2569bf801689", "postmaster_start": "2026-10-14T14:03:11.123456Z"}'
REC_STAMP='2026-10-15 07:58:21.402113'
NOW_STAMP='2026-10-15 09:12:00.000000'
TABLES=(finance_dashboard_daily finance_dashboard_arap_daily finance_dashboard_aging_daily
        finance_dashboard_expense_daily finance_dashboard_coverage)
ROWS=(8756 506202 39805 17747 9)
SEQS=(9100 610000 41000 18000 30)
COLS=('(id, company_id, date, sales, cogs, opex)'
      '(id, company_id, date, date_maturity, partner_id, is_intercompany, ar_amount, ap_amount)'
      '(id, company_id, date, date_maturity, ar_amount, ap_amount)'
      '(id, company_id, account_id, date, amount)'
      '(id, company_id, covered_from, covered_to, dirty_from, last_refresh_at, last_refresh_ok)')
WRONG=0000000000000000000000000000000000000000000000000000000000000000
PINS=$(bash "$TOOL" --list-pins)
H() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

write_record() {   # $1 = record path, $2 = archive path, then path=json overrides
    python3 - "$@" "$PINS" <<'PY'
import hashlib, json, sys
args = sys.argv[1:]
pins = dict(line.split("|") for line in args[-1].splitlines())
record_path, archive_path, overrides = args[0], args[1], args[2:-1]
tables = ["finance_dashboard_daily", "finance_dashboard_arap_daily", "finance_dashboard_aging_daily",
          "finance_dashboard_expense_daily", "finance_dashboard_coverage"]
rows = [8756, 506202, 39805, 17747, 9]
cols = ["(id, company_id, date, sales, cogs, opex)",
        "(id, company_id, date, date_maturity, partner_id, is_intercompany, ar_amount, ap_amount)",
        "(id, company_id, date, date_maturity, ar_amount, ap_amount)",
        "(id, company_id, account_id, date, amount)",
        "(id, company_id, covered_from, covered_to, dirty_from, last_refresh_at, last_refresh_ok)"]
fp = {"uuid": "629148b0-9f15-11ee-bf49-2569bf801689", "postmaster_start": "2026-10-14T14:03:11.123456Z",
      "max_aml_id": "30123456", "aml_n_tup_ins": "100", "aml_n_tup_upd": "7", "aml_n_tup_del": "0"}
archive = open(archive_path, "rb").read()
h = lambda s: hashlib.sha256(s.encode()).hexdigest()
rec = {
    "record_version": 1, "kind": "finance-dashboard reporting-layer backup", "test": True,
    "created_at": "2026-10-15T08:16:02Z", "backup_stamp": "20261015T081500Z",
    "host": "gft-odoo-report", "database": "gftuae", "restorable": True,
    "reasons": ["both assessments said NOTHING TO DO"],
    "fingerprint": dict(fp), "layer_refresh_time": "2026-10-15 07:58:21.402113",
    "archive": {"file": "fd_reporting_gftuae_20261015T081500Z.dump", "bytes": len(archive),
                "sha256": hashlib.sha256(archive).hexdigest()},
    "tables": {t: {"rows": r, "columns": c, "copy_sha256": h("rec:" + t)} for t, r, c in zip(tables, rows, cols)},
    "state_file": {"path": "/var/lib/fd-bootstrap/state.json", "sha256": h("state"), "trusted": True,
                   "not_trusted_because": None, "fingerprint": dict(fp)},
    "assessment_before": {"exit": 0, "verdict": "NOTHING TO DO", "fingerprint": dict(fp), "reasons": []},
    "assessment_after": {"exit": 0, "verdict": "NOTHING TO DO", "fingerprint": dict(fp), "reasons": []},
    "tools": {k: pins[k] for k in ("12d_verify_backup.sh", "07_backup_reporting.sh", "10_assess.sh",
                                   "10a_assess_target.sql", "10b_assess_facts.sql",
                                   "06c_validate_cross_table.sql", "09a_backup_with_record.sh")},
}
for item in overrides:
    path, _, value = item.partition("=")
    keys = path.split("/")
    node = rec
    for key in keys[:-1]:
        node = node[key]
    if value == "DELETE":
        del node[keys[-1]]
    else:
        node[keys[-1]] = json.loads(value)
with open(record_path, "w") as fh:
    fh.write(json.dumps(rec, indent=2) + "\n")
PY
}

base_facts() {     # $1 = store, $2 = tmp, $3 = case folder
    sed 's/^/file_sha:/' <<<"$PINS"
    local i t
    cat <<EOF
hostname|gft-odoo-report
pg_reads:09d_clear_all_tables.sql|true
pg_reads:06b_validate_live_inline.sql|true
pg_reads:06c_validate_cross_table.sql|true
odoo_service|inactive
odoo_processes|0
backup_meta|0:700:d
record_meta|0:400:f
register_meta|0:600:f
archive_meta|0:400:f
test_store|$1
test_tmp|$2
scope_ok|true
pre_assess_code|10
pre_assess_verdict|REFRESH
pre_fp_json|$FP
pre_module_state|installed
pre_postmaster_start|$START
pre_seq_ok|true
pre_stamp|$NOW_STAMP
pre_stamp_ok|true
test_prebackup_output|$3/prebackup.txt
test_prebackup_rc|57
final_assess_code|10
final_assess_verdict|REFRESH
final_fp_json|$FP
test_driver_output|$3/driver.txt
test_python_rc|0
test_vacuum_rc|0
EOF
    for i in 0 1 2 3 4; do
        t=${TABLES[$i]}
        cat <<EOF
ext_ok:$t|true
ext_cols:$t|${COLS[$i]}
ext_rows:$t|${ROWS[$i]}
ext_sha:$t|$(H "rec:$t")
ext_maxid:$t|${ROWS[$i]}
live_cols:$t|${COLS[$i]}
pre_hrows:$t|$(( ${ROWS[$i]} - 3 ))
pre_sha:$t|$(H "now:$t")
pre_seq:$t|${SEQS[$i]}
pre_seqname:$t|public.${t}_id_seq
pre_maxid:$t|${ROWS[$i]}
EOF
    done
}

post_facts() {     # $1 = pre|rec|other|unreadable : what a fresh connection reads afterwards
    local i t rows sha stamp
    case "$1" in
        unreadable) printf 'post_stamp_ok|false\npost_seq_ok|false\npost_module_state|unknown\n'
                    for t in "${TABLES[@]}"; do printf 'post_sha:%s|unreadable\n' "$t"; done; return ;;
    esac
    if [ "$1" = pre ]; then stamp=$NOW_STAMP; else stamp=$REC_STAMP; fi
    cat <<EOF
post_stamp_ok|true
post_stamp|$stamp
post_seq_ok|true
post_postmaster_start|$START
post_module_state|installed
post_provisioned_by|orm
post_schema_money_bad|0
post_schema_aging_bad|0
post_schema_index_missing|
post_schema_grain_missing|
post_06c_rows|7
post_06c_pass|7
EOF
    for i in 0 1 2 3 4; do
        t=${TABLES[$i]}
        if [ "$1" = pre ]; then rows=$(( ${ROWS[$i]} - 3 )) sha=$(H "now:$t")
        else rows=${ROWS[$i]} sha=$(H "rec:$t"); fi
        if [ "$1" = other ] && [ "$i" = 0 ]; then sha=$(H "other:$t"); fi
        printf 'post_hrows:%s|%s\npost_sha:%s|%s\npost_seq:%s|%s\npost_seqname:%s|public.%s_id_seq\npost_maxid:%s|%s\n' \
            "$t" "$rows" "$t" "$sha" "$t" "${SEQS[$i]}" "$t" "$t" "$t" "${ROWS[$i]}"
    done
}

driver_output() {  # $1 = variant -> FD5 lines
    local mode=rollback-only allowed=no
    case "$1" in committed|unknown|cut|live-gate|live-test) mode=live allowed=yes ;; esac
    echo "FD5|start|mode=$mode|commit_allowed=$allowed|python=3.12.3"
    echo "FD5|driver|psycopg2=2.9.9"
    echo "FD5|identity|repeatable read|gftuae|socket=True|629148b0-9f15-11ee-bf49-2569bf801689|$START"
    case "$1" in silent) return ;; esac
    echo "FD5|gate|06b|16/16|expected=16|108.20s"
    echo "FD5|gate|06c|7/7|expected=7|0.41s"
    case "$1" in
        test|live-test)  echo "FD5|sequences|unchanged"; echo "FD5|rollback|DONE"
                         echo "FD5|outcome|ROLLED_BACK|test|every check passed - a test never commits" ;;
        test-attempted)  echo "FD5|commit|ATTEMPTED"
                         echo "FD5|outcome|ROLLED_BACK|test|every check passed - a test never commits" ;;
        committed)       echo "FD5|commit|ATTEMPTED"; echo "FD5|commit|DONE"; echo "FD5|outcome|COMMITTED" ;;
        gate|live-gate)  echo "FD5|rollback|DONE"
                         echo "FD5|outcome|ROLLED_BACK|gate|1 check(s) failed: 06b sales 1.00" ;;
        error)           echo "FD5|rollback|DONE"
                         echo "FD5|outcome|ROLLED_BACK|error|OperationalError 55P03: canceling statement due to lock timeout" ;;
        refused)         echo "FD5|outcome|ROLLED_BACK|refused|finance_dashboard_daily: the data file holds 1 rows" ;;
        unknown)         echo "FD5|commit|ATTEMPTED"; echo "FD5|commit|ERROR|OperationalError: server closed the connection"
                         echo "FD5|outcome|UNKNOWN|OperationalError: server closed the connection" ;;
        cut)             echo "FD5|commit|ATTEMPTED" ;;
        none)            : ;;
        *) echo "unknown driver variant $1" >&2; exit 2 ;;
    esac
}

prebackup_output() {   # $1 = variant -> 09a's last lines
    case "$1" in
        ok57|ok0) echo "BACKUP_FOLDER=/var/backups/finance-dashboard/fd_backup_20261015T090100Z"
                  echo "BACKUP_ARCHIVE_SHA256=$(H pre-archive)"; echo "BACKUP_RECORD_SHA256=$(H pre-record)"
                  if [ "$1" = ok0 ]; then echo "BACKUP_RESTORABLE=yes"; echo "BACKUP_RESULT=0"
                  else echo "BACKUP_RESTORABLE=no"; echo "BACKUP_RESULT=57"; fi ;;
        fail55)   echo "BACKUP_RESTORABLE=no"; echo "BACKUP_RESULT=55" ;;
        fail56)   echo "BACKUP_FOLDER=/var/backups/finance-dashboard/FAILED_fd_backup_20261015T090100Z"
                  echo "BACKUP_RESTORABLE=no"; echo "BACKUP_RESULT=56" ;;
        fail2)    echo "BACKUP_RESTORABLE=no"; echo "BACKUP_RESULT=2" ;;
    esac
}

n=0 failures=0
OUT= RC=
# case_ EXIT EXECUTED COMMITTED VACUUMED PREBACKUP FINGERPRINT "name" "mode flags" driver post [overrides...]
#   mode flags may hold @ARCH@ / @REC@ (the real hashes, computed here) and @WRONG@
#   overrides: 'key|value' facts | rec:a/b=json (DELETE removes) | @reg:none|two|result57|recsha|archsha
#              | @archive:changed|samesize | @record:corrupt | @backup:elsewhere|failedname | @pre:<variant>
case_() {
    local want=("$1" "$2" "$3" "$4" "$5" "$6") name=$7 flags=$8 driver=$9 post=${10}
    shift 10
    n=$((n + 1))
    local cdir="$WORK_T/c$n" store tmp folder reg_variant=normal pre_variant=ok57 backup o
    store="$cdir/store" tmp="$cdir/tmp" folder="$cdir/store/$FOLDER"
    mkdir -p "$folder" "$tmp"
    printf 'stand-in archive for case %s\n' "$n" > "$folder/$ARCHIVE"
    local rec_over=() facts_over=() special=()
    for o in "$@"; do
        case "$o" in
            rec:*) rec_over+=("${o#rec:}") ;;
            @reg:*) reg_variant=${o#@reg:} ;;
            @pre:*) pre_variant=${o#@pre:} ;;
            @*) special+=("$o") ;;
            *) facts_over+=("$o") ;;
        esac
    done
    write_record "$folder/record.json" "$folder/$ARCHIVE" "${rec_over[@]+"${rec_over[@]}"}"
    local arch_sha rec_sha
    arch_sha=$(sha256sum "$folder/$ARCHIVE" | awk '{print $1}')
    rec_sha=$(sha256sum "$folder/record.json" | awk '{print $1}')
    {
        printf '# created_utc\tfolder\tresult\trestorable\tarchive_sha256\trecord_sha256\n'
        case "$reg_variant" in
            normal)   printf '2026-10-15T08:16:03Z\t%s\t0\tyes\t%s\t%s\n' "$FOLDER" "$arch_sha" "$rec_sha" ;;
            none)     printf '2026-10-15T08:16:03Z\tfd_backup_20261014T000000Z\t0\tyes\t%s\t%s\n' "$arch_sha" "$rec_sha" ;;
            two)      printf '2026-10-15T08:16:03Z\t%s\t0\tyes\t%s\t%s\n' "$FOLDER" "$arch_sha" "$rec_sha"
                      printf '2026-10-15T08:16:04Z\t%s\t0\tyes\t%s\t%s\n' "$FOLDER" "$arch_sha" "$rec_sha" ;;
            result57) printf '2026-10-15T08:16:03Z\t%s\t57\tno\t%s\t%s\n' "$FOLDER" "$arch_sha" "$rec_sha" ;;
            recsha)   printf '2026-10-15T08:16:03Z\t%s\t0\tyes\t%s\t%s\n' "$FOLDER" "$arch_sha" "$WRONG" ;;
            archsha)  printf '2026-10-15T08:16:03Z\t%s\t0\tyes\t%s\t%s\n' "$FOLDER" "$WRONG" "$rec_sha" ;;
        esac
    } > "$store/register.tsv"
    backup=$folder
    for o in "${special[@]+"${special[@]}"}"; do
        case "$o" in
            @archive:changed) printf 'changed after the backup\n' >> "$folder/$ARCHIVE" ;;
            @archive:samesize) printf 'X' | dd of="$folder/$ARCHIVE" bs=1 seek=0 conv=notrunc 2>/dev/null ;;
            @record:corrupt)  printf '{"record_version": 1, "test": tru' > "$folder/record.json"
                              rec_sha=$(sha256sum "$folder/record.json" | awk '{print $1}') ;;
            @backup:elsewhere) mkdir -p "$cdir/elsewhere"; cp -R "$folder" "$cdir/elsewhere/"; backup="$cdir/elsewhere/$FOLDER" ;;
            @backup:failedname) mv "$folder" "$store/FAILED_$FOLDER"; backup="$store/FAILED_$FOLDER" ;;
            *) echo "unknown special $o" >&2; exit 2 ;;
        esac
    done
    driver_output "$driver" > "$cdir/driver.txt"
    prebackup_output "$pre_variant" > "$cdir/prebackup.txt"
    local facts="$cdir/facts.txt"
    { base_facts "$store" "$tmp" "$cdir"; if [ "$post" != none ]; then post_facts "$post"; fi
      for o in "${facts_over[@]+"${facts_over[@]}"}"; do printf '%s\n' "$o"; done; } > "$facts"
    flags=${flags//@ARCH@/$arch_sha}
    flags=${flags//@REC@/$rec_sha}
    flags=${flags//@WRONG@/$WRONG}
    local -a argv
    read -r -a argv <<<"$flags"
    RC=0
    OUT=$(bash "$TOOL" --facts "$facts" --backup "$backup" "${argv[@]}" 2>&1) || RC=$?
    local got=("$RC"
        "$(awk -F= '/^TRANSACTION_EXECUTED=/ {v = $2} END {print (v == "" ? "-" : v)}' <<<"$OUT")"
        "$(awk -F= '/^TRANSACTION_COMMITTED=/ {v = $2} END {print (v == "" ? "-" : v)}' <<<"$OUT")"
        "$(awk -F= '/^VACUUM_EXECUTED=/ {v = $2} END {print (v == "" ? "-" : v)}' <<<"$OUT")"
        "$(awk '/^PRE_RESTORE_BACKUP=/ {v = (($0 == "PRE_RESTORE_BACKUP=none") ? "no" : "yes")} END {print (v == "" ? "-" : v)}' <<<"$OUT")"
        "$(grep -q '^RECORD_FINGERPRINT_JSON=' <<<"$OUT" && echo yes || echo no)")
    local left
    left=$(ls -A "$tmp" | grep -E '^fd_section5_(work|data)_' || true)
    if [ "${got[*]}" = "${want[*]}" ] && [ -z "$left" ]; then
        printf 'PASS  %2s  %-66s\n' "$RC" "$name"
    else
        printf 'FAIL  %2s  %-66s want %s got %s%s\n' "$RC" "$name" "${want[*]}" "${got[*]}" "${left:+ left behind: $left}"
        printf '%s\n' "$OUT" | grep -E '^  - |^result|^RESULT|ERROR|^09_restore' | sed 's/^/        | /' | head -n 12
        failures=$((failures + 1))
    fi
}

LIVE_OK='--live --confirm-archive @ARCH@ --confirm-record @REC@'
# ---- passing runs ---------------------------------------------------------------------------------
case_  0 no  no  no  no  no  "dry run: every pre-check passes, nothing started"              "--dry-run" test none
case_  0 no  no  no  no  no  "dry run --live: the confirmations checked too"                  "--dry-run $LIVE_OK" test none
case_  0 yes no  no  no  no  "rollback-only: passed, a fresh read shows nothing changed"     "--rollback-only" test pre
case_  0 yes yes yes yes yes "live: restored, verified, vacuumed; fingerprint printed"       "$LIVE_OK" committed rec
case_  0 yes yes yes yes yes "live: the pre-restore backup restorable (0) is fine too"       "$LIVE_OK" committed rec @pre:ok0 'test_prebackup_rc|0'
case_ 54 yes yes yes yes yes "live: a sequence below the restored max(id) -> 54, shown only" "$LIVE_OK" committed rec 'post_seq:finance_dashboard_daily|8000'
case_ 54 yes yes yes yes yes "live: a sequence never used (empty) -> 54"                     "$LIVE_OK" committed rec 'post_seq:finance_dashboard_coverage|'
case_ 54 yes yes yes yes yes "live: VACUUM fails -> 54, data stays"                          "$LIVE_OK" committed rec 'test_vacuum_rc|1'
# ---- refused before the transaction (50) ------------------------------------------------------------
for key in $(cut -d'|' -f1 <<<"$PINS"); do
    case_ 50 no no no no no "pin mismatch: $key"                                             "--rollback-only" test none "file_sha:$key|$WRONG"
done
case_ 50 no no no no no "postgres cannot read 06b"                                          "--rollback-only" test none 'pg_reads:06b_validate_live_inline.sql|false'
case_ 50 no no no no no "Odoo service active"                                               "--rollback-only" test none 'odoo_service|active'
case_ 50 no no no no no "an Odoo process running"                                           "--rollback-only" test none 'odoo_processes|1'
case_ 50 no no no no no "backup folder outside the store"                                   "--rollback-only" test none @backup:elsewhere
case_ 50 no no no no no "a FAILED_ folder named as the backup"                              "--rollback-only" test none @backup:failedname
case_ 50 no no no no no "backup folder owned by ubuntu"                                     "--rollback-only" test none 'backup_meta|1001:700:d'
case_ 50 no no no no no "backup folder mode 0755"                                           "--rollback-only" test none 'backup_meta|0:755:d'
case_ 50 no no no no no "backup folder is a link"                                           "--rollback-only" test none 'backup_meta|0:777:l'
case_ 50 no no no no no "record.json mode 0644"                                             "--rollback-only" test none 'record_meta|0:644:f'
case_ 50 no no no no no "archive mode 0600"                                                 "--rollback-only" test none 'archive_meta|0:600:f'
case_ 50 no no no no no "register mode 0644"                                                "--rollback-only" test none 'register_meta|0:644:f'
case_ 50 no no no no no "register missing"                                                  "--rollback-only" test none 'register_meta|missing'
case_ 50 no no no no no "record.json is not JSON"                                           "--rollback-only" test none @record:corrupt
case_ 50 no no no no no "a real record in a test (test=false)"                              "--rollback-only" test none 'rec:test=false'
case_ 50 no no no no no "record from another host"                                          "--rollback-only" test none 'rec:host="gft-odoo"'
case_ 50 no no no no no "record for another database"                                       "--rollback-only" test none 'rec:database="gftuae2"'
case_ 50 no no no no no "record NOT restorable (evidence only)"                             "--rollback-only" test none 'rec:restorable=false'
case_ 50 no no no no no "assessment at backup time was REFRESH"                             "--rollback-only" test none 'rec:assessment_before/exit=10' 'rec:assessment_before/verdict="REFRESH"'
case_ 50 no no no no no "record fingerprint incomplete"                                     "--rollback-only" test none 'rec:fingerprint/max_aml_id=DELETE'
case_ 50 no no no no no "record uuid another database's"                                    "--rollback-only" test none 'rec:fingerprint/uuid="deadbeef"'
case_ 50 no no no no no "record refresh time not valid"                                     "--rollback-only" test none 'rec:layer_refresh_time=""'
case_ 50 no no no no no "record lists four tables"                                          "--rollback-only" test none 'rec:tables/finance_dashboard_coverage=DELETE'
case_ 50 no no no no no "record made by another 09a"                                        "--rollback-only" test none "rec:tools/09a_backup_with_record.sh=\"$WRONG\""
case_ 50 no no no no no "record version 2"                                                  "--rollback-only" test none 'rec:record_version=2'
case_ 50 no no no no no "register: no line for this folder"                                 "--rollback-only" test none @reg:none
case_ 50 no no no no no "register: two lines for this folder"                               "--rollback-only" test none @reg:two
case_ 50 no no no no no "register: the line says 57 (evidence only)"                        "--rollback-only" test none @reg:result57
case_ 50 no no no no no "record changed after the backup (register hash)"                   "--rollback-only" test none @reg:recsha
case_ 50 no no no no no "register's archive hash differs"                                   "--rollback-only" test none @reg:archsha
case_ 50 no no no no no "archive changed after the backup"                                  "--rollback-only" test none @archive:changed
case_ 50 no no no no no "archive changed, same size: only its SHA-256 shows it"              "--rollback-only" test none @archive:samesize
case_ 50 no no no no no "live: --confirm-archive wrong"                                     "--live --confirm-archive @WRONG@ --confirm-record @REC@" committed none
case_ 50 no no no no no "[B] live: --confirm-record wrong"                                  "--live --confirm-archive @ARCH@ --confirm-record @WRONG@" committed none
case_ 50 no no no no no "dry run --live: a wrong confirmation is caught"                    "--dry-run --live --confirm-archive @WRONG@ --confirm-record @REC@" test none
case_ 50 no no no no no "archive holds a table outside the five"                            "--rollback-only" test none 'scope_ok|false' 'scope_detail|tables [public.x]'
case_ 50 no no no no no "a table's data unreadable in the archive"                          "--rollback-only" test none 'ext_ok:finance_dashboard_aging_daily|false'
case_ 50 no no no no no "archive columns differ from the record"                            "--rollback-only" test none 'ext_cols:finance_dashboard_daily|(id, x)'
case_ 50 no no no no no "archive rows differ from the record"                               "--rollback-only" test none "ext_sha:finance_dashboard_arap_daily|$WRONG"
case_ 50 no no no no no "assessment 11 (module not installed)"                              "--rollback-only" test none 'pre_assess_code|11'
case_ 50 no no no no no "assessment 20 (wrong target)"                                      "--rollback-only" test none 'pre_assess_code|20'
case_ 50 no no no no no "assessment 21 (pending modules)"                                   "--rollback-only" test none 'pre_assess_code|21'
case_ 50 no no no no no "assessment 22 (layer anomaly)"                                     "--rollback-only" test none 'pre_assess_code|22'
case_ 50 no no no no no "assessment 2 (could not complete)"                                 "--rollback-only" test none 'pre_assess_code|2'
case_ 50 no no no no no "module state not installed"                                        "--rollback-only" test none 'pre_module_state|to upgrade'
case_ 50 no no no no no "ledger changed since the backup (max_aml_id)"                      "--rollback-only" test none "pre_fp_json|$FP_LEDGER"
case_ 50 no no no no no "cluster restarted since the backup"                                "--rollback-only" test none "pre_fp_json|$FP_RESTART"
case_ 50 no no no no no "assessment fingerprint incomplete"                                 "--rollback-only" test none "pre_fp_json|$FP_SHORT"
case_ 50 no no no no no "live columns differ (schema changed)"                              "--rollback-only" test none 'live_cols:finance_dashboard_coverage|(id, company_id)'
case_ 50 no no no no no "current rows unreadable"                                           "--rollback-only" test none 'pre_sha:finance_dashboard_daily|unreadable'
case_ 50 no no no no no "sequences unreadable"                                              "--rollback-only" test none 'pre_seq_ok|false'
case_ 50 no no no no no "live: pre-restore backup refused (55)"                             "$LIVE_OK" committed none @pre:fail55 'test_prebackup_rc|55'
case_ 50 no no no no no "live: pre-restore backup unusable (56)"                            "$LIVE_OK" committed none @pre:fail56 'test_prebackup_rc|56'
case_ 50 no no no no no "live: pre-restore backup could not run (2)"                        "$LIVE_OK" committed none @pre:fail2 'test_prebackup_rc|2'
case_ 50 no no no no no "live: pre-restore backup exit 0 but result line 57"                "$LIVE_OK" committed none 'test_prebackup_rc|0'
case_ 50 no no no yes no "live: assessment after the backup says 22"                        "$LIVE_OK" committed none 'final_assess_code|22'
case_ 50 no no no yes no "live: fingerprint moved during the pre-restore backup"            "$LIVE_OK" committed none "final_fp_json|$FP_LEDGER"
# ---- the transaction and what the fresh read shows --------------------------------------------------
case_ 52 yes no  no  no  no  "rollback-only: a check fails -> 52, confirmed unchanged"      "--rollback-only" gate pre
case_ 51 yes no  no  no  no  "rollback-only: driver error -> 51"                            "--rollback-only" error pre
case_ 51 yes no  no  no  no  "rollback-only: driver refused -> 51"                          "--rollback-only" refused pre
case_ 51 yes no  no  no  no  "rollback-only: no outcome, no commit attempt -> 51"           "--rollback-only" silent pre
case_ 51 yes no  no  no  no  "rollback-only: passed but python exited 1 -> 51"             "--rollback-only" test pre 'test_python_rc|1'
case_ 51 yes no  no  no  no  "rollback-only: passed but the fresh read failed -> 51"        "--rollback-only" test unreadable
case_ 53 yes unknown no no no "rollback-only: passed but the layer is not as before -> 53"  "--rollback-only" test rec
case_ 53 yes unknown no no no "rollback-only: sequences moved -> 53"                         "--rollback-only" test pre 'post_seq:finance_dashboard_arap_daily|610001'
case_ 53 yes unknown no no no "rollback-only: a commit attempt reported -> 53"              "--rollback-only" test-attempted pre
case_ 53 yes unknown no no no "rollback-only: a check fails and the layer changed -> 53"    "--rollback-only" gate rec
case_ 52 yes no  no  yes no  "live: a check fails -> 52"                                    "$LIVE_OK" live-gate pre
case_ 51 yes no  no  yes no  "live: the driver ran as a test -> 51"                         "$LIVE_OK" live-test pre
case_ 53 yes unknown no yes no "live: commit raised; restored data in place -> 53"           "$LIVE_OK" unknown rec
case_ 53 yes unknown no yes no "live: commit raised; previous data in place -> 53"           "$LIVE_OK" unknown pre
case_ 53 yes unknown no yes no "live: commit attempted, no outcome -> 53"                    "$LIVE_OK" cut rec
case_ 53 yes yes no  yes no  "live: committed but a table differs from the record -> 53"    "$LIVE_OK" committed other
case_ 53 yes yes no  yes no  "live: committed but the cluster restarted -> 53"              "$LIVE_OK" committed rec "post_postmaster_start|2026-10-15T10:00:00.000000Z"
case_ 53 yes yes no  yes no  "live: committed but 06c 6/7 -> 53"                            "$LIVE_OK" committed rec 'post_06c_pass|6'
case_ 53 yes yes no  yes no  "live: committed but python exited 1 -> 53"                    "$LIVE_OK" committed rec 'test_python_rc|1'
case_ 53 yes yes no  yes no  "live: committed but unreadable afterwards -> 53"              "$LIVE_OK" committed unreadable
case_ 53 yes unknown no no no "an error after the transaction started -> 53, never 2"        "--rollback-only" test pre 'test_die_after_transaction|yes'
# ---- arguments (2, nothing started) ------------------------------------------------------------------
case_  2 -   -   -   -   no  "no mode"                                                       "" test none
case_  2 -   -   -   -   no  "--live with --rollback-only"                                   "--live --rollback-only --confirm-archive @ARCH@ --confirm-record @REC@" test none
case_  2 -   -   -   -   no  "--live without --confirm-archive"                              "--live --confirm-record @REC@" test none
case_  2 -   -   -   -   no  "[B] --live without --confirm-record"                           "--live --confirm-archive @ARCH@" test none
case_  2 -   -   -   -   no  "--confirm-archive not 64 hex"                                  "--live --confirm-archive abc --confirm-record @REC@" test none
case_  2 -   -   -   -   no  "confirmations without --live"                                  "--rollback-only --confirm-archive @ARCH@" test none
case_  2 -   -   -   -   no  "--state-file relative"                                         "--rollback-only --state-file state.json" test none
case_  2 -   -   -   -   no  "unknown argument"                                              "--rollback-only --force" test none
case_  2 -   -   -   -   no  "a test naming the real store"                                  "--rollback-only" test none 'test_store|/var/backups/finance-dashboard'
# --backup missing / relative: run directly (case_ always passes --backup)
for args in "--rollback-only --facts $WORK_T/c1/facts.txt" "--rollback-only --backup relative/fd_backup_x --facts $WORK_T/c1/facts.txt"; do
    n=$((n + 1)); RC=0; read -r -a argv <<<"$args"
    OUT=$(bash "$TOOL" "${argv[@]}" 2>&1) || RC=$?
    if [ "$RC" = 2 ] && grep -q '^RESULT=2$' <<<"$OUT"; then printf 'PASS   2  %-66s\n' "--backup missing or relative: $args"
    else printf 'FAIL  %2s  %-66s\n' "$RC" "--backup missing or relative"; failures=$((failures + 1)); fi
done

# ---- the 09a rehearsal's REAL archive, record and register ------------------------------------------
if [ -n "$REHEARSAL_STORE" ] && [ -d "$REHEARSAL_STORE" ]; then
    for variant in rollback live; do
        n=$((n + 1))
        cdir="$WORK_T/real_$variant"; mkdir -p "$cdir/tmp" "$cdir/data"
        cp -R "$REHEARSAL_STORE" "$cdir/store"
        real_folder=$(ls -d "$cdir"/store/fd_backup_* | head -n 1)
        python3 - "$real_folder/record.json" "$cdir/real_facts.txt" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
fp = rec["fingerprint"]
lines = ["pre_fp_json|" + json.dumps(fp), "final_fp_json|" + json.dumps(fp),
         "pre_postmaster_start|" + fp["postmaster_start"], "post_postmaster_start|" + fp["postmaster_start"],
         "pre_stamp|" + rec["layer_refresh_time"]]
for t, v in rec["tables"].items():
    lines += ["live_cols:%s|%s" % (t, v["columns"]), "pre_hrows:%s|%d" % (t, v["rows"]),
              "pre_sha:%s|%s" % (t, v["copy_sha256"]), "pre_seq:%s|%d" % (t, v["rows"]),
              "pre_seqname:%s|public.%s_id_seq" % (t, t), "pre_maxid:%s|%d" % (t, v["rows"]),
              "post_hrows:%s|%d" % (t, v["rows"]), "post_sha:%s|%s" % (t, v["copy_sha256"]),
              "post_seq:%s|%d" % (t, v["rows"]), "post_seqname:%s|public.%s_id_seq" % (t, t),
              "post_maxid:%s|%d" % (t, v["rows"])]
lines += ["post_stamp|" + rec["layer_refresh_time"]]
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PY
        {
            sed 's/^/file_sha:/' <<<"$PINS"
            printf 'hostname|gft-odoo-report\nodoo_service|inactive\nodoo_processes|0\n'
            printf 'pg_reads:09d_clear_all_tables.sql|true\npg_reads:06b_validate_live_inline.sql|true\npg_reads:06c_validate_cross_table.sql|true\n'
            printf 'backup_meta|0:700:d\nrecord_meta|0:400:f\nregister_meta|0:600:f\narchive_meta|0:400:f\n'
            printf 'test_store|%s\ntest_tmp|%s\ntest_extract_real|yes\ntest_data_root|%s\n' "$cdir/store" "$cdir/tmp" "$cdir/data"
            printf 'pre_assess_code|0\npre_assess_verdict|NOTHING TO DO\npre_module_state|installed\npre_seq_ok|true\npre_stamp_ok|true\n'
            printf 'final_assess_code|0\nfinal_assess_verdict|NOTHING TO DO\n'
            printf 'test_prebackup_output|%s\ntest_prebackup_rc|0\n' "$cdir/prebackup.txt"
            printf 'test_driver_output|%s\ntest_python_rc|0\ntest_vacuum_rc|0\n' "$REHEARSAL_STORE/../driver_$variant.out"
            printf 'post_stamp_ok|true\npost_seq_ok|true\npost_module_state|installed\npost_provisioned_by|orm\n'
            printf 'post_schema_money_bad|0\npost_schema_aging_bad|0\npost_schema_index_missing|\npost_schema_grain_missing|\npost_06c_rows|7\npost_06c_pass|7\n'
            cat "$cdir/real_facts.txt"
        } > "$cdir/facts.txt"
        prebackup_output ok0 > "$cdir/prebackup.txt"
        arch_sha=$(sha256sum "$real_folder"/fd_reporting_*.dump | awk '{print $1}')
        rec_sha=$(sha256sum "$real_folder/record.json" | awk '{print $1}')
        if [ "$variant" = rollback ]; then mode=(--rollback-only); want="0 yes no no no no"
        else mode=(--live --confirm-archive "$arch_sha" --confirm-record "$rec_sha"); want="0 yes yes yes yes yes"; fi
        RC=0
        OUT=$(PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH" bash "$TOOL" --facts "$cdir/facts.txt" --backup "$real_folder" "${mode[@]}" 2>&1) || RC=$?
        got="$RC $(awk -F= '/^TRANSACTION_EXECUTED=/ {print $2}' <<<"$OUT") $(awk -F= '/^TRANSACTION_COMMITTED=/ {print $2}' <<<"$OUT") $(awk -F= '/^VACUUM_EXECUTED=/ {print $2}' <<<"$OUT") $(grep -q '^PRE_RESTORE_BACKUP=none' <<<"$OUT" && echo no || echo yes) $(grep -q '^RECORD_FINGERPRINT_JSON=' <<<"$OUT" && echo yes || echo no)"
        data_left=$(ls -A "$cdir/data" | wc -l | tr -d ' ')
        if [ "$got" = "$want" ] && [ "$data_left" = 0 ]; then
            printf 'PASS  %2s  %-66s\n' "$RC" "REAL archive/record/register, pg_restore + real driver output: $variant"
        else
            printf 'FAIL  %2s  %-66s want %s got %s (data folders left: %s)\n' "$RC" "REAL ... $variant" "$want" "$got" "$data_left"
            printf '%s\n' "$OUT" | grep -E '^  - |^result|ERROR' | sed 's/^/        | /' | head -n 12
            failures=$((failures + 1))
        fi
    done
else
    echo "SKIP  the REAL-archive cases: pass the 09a rehearsal store as the first argument"
fi
echo "------------------------------------------------------------"
echo "$n cases: $((n - failures)) PASS, $failures FAIL"
[ "$failures" = 0 ]
