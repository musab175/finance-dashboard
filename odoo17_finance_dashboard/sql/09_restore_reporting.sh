#!/usr/bin/env bash
# =============================================================================
# 09_restore_reporting.sh - Finance Dashboard bootstrap, SECTION 5: RESTORE the
# reporting layer from a verified backup. 2026-10-15.
#
# WHEN A RESTORE IS ALLOWED (approved 2026-10-14): only from a backup whose
# record says RESTORABLE - the assessment at backup time said NOTHING TO DO -
# and only while the ledger fingerprint still equals the recorded one. After a
# ledger change or a replacement, recovery means fixing the cause and
# rebuilding (Section 4), never putting back an older layer.
#
#   1. Pre-checks, read-only   every file this run uses matches its pinned
#                              SHA-256; postgres can read the files the driver
#                              opens; Odoo stopped, no Odoo process; the backup
#                              folder, its record, its register line and its
#                              archive are root's, unchanged and agree with each
#                              other; the archive holds exactly the five tables
#                              and every table's rows re-hash to the record;
#                              --live: the archive's AND the record's full
#                              SHA-256, typed by the operator from the vault; a
#                              fresh assessment (0 or 10: module installed,
#                              layer sound), its fingerprint equal to the
#                              record's; the live columns equal the archive's
#   2. Read now                the CURRENT layer from a fresh connection: every
#                              table's rows and sorted-row SHA-256, the refresh
#                              time, 06c, each id sequence against the archive's
#                              highest id - the same code that decides success
#                              after a commit, run read-only in every mode
#   3. Pre-restore backup      --live only: 09a backs up the current layer,
#                              verified (0 or 57), before anything is written;
#                              then the fingerprint is checked once more
#   4. The transaction         09b_restore_transaction.py as postgres: clear,
#                              load, compare, 06b + 06c, sequences; COMMIT only
#                              for --live and only if all of it passed
#   5. Read again              a FRESH connection. After a COMMIT: every table,
#                              the refresh time and 06c equal the record, the
#                              schema is clean, the same cluster start, each id
#                              sequence at or above its table's max(id); then
#                              VACUUM (ANALYZE) on the five tables. After a
#                              ROLLBACK: the layer and the sequences are exactly
#                              as step 2 read them
#
# EXIT CODES
#   0   --dry-run or --rollback-only passed and nothing changed (confirmed from a
#       fresh connection), or --live committed, verified and vacuumed
#   50  refused before the transaction: no database write (a pre-restore
#       backup, if one was made, is kept)
#   51  technical failure inside the transaction: rolled back, nothing committed
#   52  a comparison or one of the 23 checks failed: rolled back, nothing committed
#   53  NO guarantee: the commit could not be confirmed, or a fresh connection
#       does not show what the outcome says. The fresh check reports which data
#       is in place; for --live the pre-restore backup exists
#   54  committed and verified, but VACUUM failed or an id sequence is below its
#       table's max(id): the data is correct and stays; the exact command is
#       shown and never run by this script
#   2   this script could not run - only ever before the transaction
# Any other exit code (1, 127, 141 ...) is an unexpected abort: treat it as 53.
# NOTHING COMMITTED, guaranteed: 0 for --dry-run and --rollback-only, 50, 51,
# 52, 2 - the driver never reached its one commit() call.
#
# MODES - exactly one, always with --backup FOLDER (an fd_backup_<UTC> folder
# in /var/backups/finance-dashboard):
#   --dry-run                  pre-checks and the read of the current layer;
#                              nothing is started
#   --dry-run --live --confirm-archive SHA --confirm-record SHA
#                              the same, plus the two confirmations
#   --rollback-only            the whole transaction, then ROLLBACK
#   --live --confirm-archive SHA --confirm-record SHA
#                              the real restore - only with its own approval.
#                              Type both values from the VAULT, never copy them
#                              from this server's output.
# [B] --confirm-record is PENDING DECISION B (2026-10-14). If it is declined,
#     remove the lines marked [B] here and the harness cases marked [B].
#
# NEVER: setval, VACUUM FULL, -i or -u, a retry, starting or stopping Odoo,
# writing the state file, deleting a backup.
#
# FILES: logs in a NEW /tmp/fd_section5_restore_<UTC> (root, 0700): pre-restore
# backup output, driver.out (FD5 lines), driver.err, result.txt. The data the
# driver loads goes to a NEW /tmp/fd_section5_data_<UTC> (postgres, 0700) and is
# deleted at the end, as is the root-only work folder.
#
# USAGE
#   sudo bash 09_restore_reporting.sh --backup FOLDER --dry-run
#   sudo bash 09_restore_reporting.sh --backup FOLDER --rollback-only
#   sudo bash 09_restore_reporting.sh --backup FOLDER --live \
#        --confirm-archive SHA256 --confirm-record SHA256
#   bash 09_restore_reporting.sh --list-pins
#   bash 09_restore_reporting.sh --facts FILE --backup FOLDER <mode>   (test)
#        made-up facts, a scratch store named in the facts; never as root
#
# The same folder must hold, all pinned: 09a_backup_with_record.sh,
# 09b_restore_transaction.py, 09d_clear_all_tables.sql,
# 06b_validate_live_inline.sql, 06c_validate_cross_table.sql,
# 12d_verify_backup.sh, 07_backup_reporting.sh, 10_assess.sh,
# 10a_assess_target.sql, 10b_assess_facts.sql.
# =============================================================================
set -euo pipefail

ODOO_BIN=/mnt/data/app/bin/odoo
ODOO_SERVICE=odoo
EXPECTED_HOSTNAME=gft-odoo-report
DATABASE=gftuae
EXPECTED_UUID=629148b0-9f15-11ee-bf49-2569bf801689
SOCKET_DIR=/var/run/postgresql
SOCKET_PORT=5432
LOCK_TIMEOUT=60s
STORE=/var/backups/finance-dashboard
STATE_FILE=/var/lib/fd-bootstrap/state.json
TMP_ROOT=/tmp
TABLES=(finance_dashboard_daily finance_dashboard_arap_daily
        finance_dashboard_aging_daily finance_dashboard_expense_daily
        finance_dashboard_coverage)
# The SAME text 12_refresh.sh, 12a, 09a and 09b use.
STAMP_SQL="SELECT COALESCE(to_char(max(last_refresh_at), 'YYYY-MM-DD HH24:MI:SS.US'), '') FROM finance_dashboard_coverage"
# Read the tables the way pg_dump wrote the archive (09b, step 1).
COPY_OPTIONS='-c default_transaction_read_only=on -c DateStyle=ISO -c IntervalStyle=postgres -c extra_float_digits=3'

PIN_KEYS=(09a_backup_with_record.sh 09b_restore_transaction.py 09d_clear_all_tables.sql
          06b_validate_live_inline.sql 06c_validate_cross_table.sql 12d_verify_backup.sh
          07_backup_reporting.sh 10_assess.sh 10a_assess_target.sql 10b_assess_facts.sql)
declare -A PIN=(
    [09a_backup_with_record.sh]=e8b9eed8fec4d573e5f4fcc855c22a1401b797bdabf7495564335b92d2afe039
    [09b_restore_transaction.py]=5b1fcf3afbdf2122914a35b50c59e3ca8367141116d942f5cc0fc5ee93302349
    [09d_clear_all_tables.sql]=67d1e181ab7184832005e93bb3a57a018531ce4c9debf3f529e0064294edcdcf
    [06b_validate_live_inline.sql]=dae76d6782878e646a970c980d09952e4715c07865f49a0afaadebb315e14f41
    [06c_validate_cross_table.sql]=4c008824249f86bd2c1065c22eb32bea0687a2542d527ba2c21bdd71e6905708
    [12d_verify_backup.sh]=ba405fdcbd7303bf0c8de4993a2aab3dc14ed263c92e1b7f389054433987d980
    [07_backup_reporting.sh]=e72c757a1bd13672f98115c89670621fef0f735f4856959500fd1d909a5935c8
    [10_assess.sh]=067b7e4f11de389cb49caea4d902a547b6204c18c91f4d0e5d0306b4548870e5
    [10a_assess_target.sql]=b6b9da8d51099f03c4ca82b5f109b73bf0a0430202f15671f50ac6e554bc340a
    [10b_assess_facts.sql]=37809ddc91cc74a5bf7619dea032761b4e6ba64996444fd77d1f598db7637dab
)
# Files the assessment runs: checked BEFORE it is run, because it runs as root.
ASSESS_KEYS=(10_assess.sh 10a_assess_target.sql 10b_assess_facts.sql 06c_validate_cross_table.sql)
# Files the driver opens itself, as postgres; it re-checks each against the same pin.
DRIVER_KEYS=(09d_clear_all_tables.sql 06b_validate_live_inline.sql 06c_validate_cross_table.sql)
# The tools a record names: they must be exactly the pinned ones.
RECORD_TOOL_KEYS=(09a_backup_with_record.sh 12d_verify_backup.sh 07_backup_reporting.sh
                  10_assess.sh 10a_assess_target.sql 10b_assess_facts.sql 06c_validate_cross_table.sql)
RE_FOLDER='^fd_backup_[0-9]{8}T[0-9]{6}Z$'
RE_ARCHIVE='^fd_reporting_gftuae_[0-9]{8}T[0-9]{6}Z\.dump$'
RE_SHA='^[0-9a-f]{64}$'
RE_STAMP='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
LIVE=0
ROLLBACK_ONLY=0
BACKUP=
CONFIRM_ARCHIVE=
CONFIRM_RECORD=
FACTS_FILE=

usage() { echo "09_restore_reporting.sh: $*" >&2; echo "RESULT=2"; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)         DRY_RUN=1; shift ;;
        --rollback-only)   ROLLBACK_ONLY=1; shift ;;
        --live)            LIVE=1; shift ;;
        --backup)          BACKUP=${2:-}; [ -n "$BACKUP" ] || usage "--backup needs a folder"; shift 2 ;;
        --confirm-archive) CONFIRM_ARCHIVE=${2:-}; [ -n "$CONFIRM_ARCHIVE" ] || usage "--confirm-archive needs a SHA-256"; shift 2 ;;
        --confirm-record)  CONFIRM_RECORD=${2:-}; [ -n "$CONFIRM_RECORD" ] || usage "--confirm-record needs a SHA-256"; shift 2 ;;   # [B]
        --state-file)      STATE_FILE=${2:-}; [ -n "$STATE_FILE" ] || usage "--state-file needs a path"; shift 2 ;;
        --facts)           FACTS_FILE=${2:-}; [ -n "$FACTS_FILE" ] || usage "--facts needs a file"; shift 2 ;;
        --list-pins)
            for key in "${PIN_KEYS[@]}"; do printf '%s|%s\n' "$key" "${PIN[$key]}"; done
            exit 0 ;;
        *) usage "unknown argument: $1" ;;
    esac
done
if [ "$LIVE" = 1 ] && [ "$ROLLBACK_ONLY" = 1 ]; then
    usage "--live cannot be combined with --rollback-only"
fi
if [ "$LIVE" = 0 ] && [ "$ROLLBACK_ONLY" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    usage "choose a mode: --dry-run, --rollback-only or --live"
fi
[ -n "$BACKUP" ] || usage "--backup FOLDER is required: an fd_backup_<UTC> folder in $STORE"
case "$BACKUP" in /*) ;; *) usage "--backup must be an absolute path, not '$BACKUP'" ;; esac
case "$STATE_FILE" in /*) ;; *) usage "--state-file must be an absolute path, not '$STATE_FILE'" ;; esac
BACKUP=${BACKUP%/}
if [ "$LIVE" = 1 ]; then
    [ -n "$CONFIRM_ARCHIVE" ] || usage "--live needs --confirm-archive: the archive's SHA-256 from the vault"
    [ -n "$CONFIRM_RECORD" ] || usage "--live needs --confirm-record: the record's SHA-256 from the vault"   # [B]
    [[ $CONFIRM_ARCHIVE =~ $RE_SHA ]] || usage "--confirm-archive must be the full 64-character SHA-256"
    [[ $CONFIRM_RECORD =~ $RE_SHA ]] || usage "--confirm-record must be the full 64-character SHA-256"       # [B]
elif [ -n "$CONFIRM_ARCHIVE$CONFIRM_RECORD" ]; then
    usage "--confirm-archive and --confirm-record belong to --live only"
fi
if [ "$LIVE" = 1 ]; then TXN_MODE=live; else TXN_MODE=rollback-only; fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
TRANSACTION_EXECUTED=no
COMMITTED=no
VACUUM_EXECUTED=no
VACUUM_RC=
NEED_VACUUM=no
FRESH=no
PY_RC=
CODE=
REFUSE=()
REASONS=()
CMD=()
CREATED=()          # folders this run made and removes at the end (data, work)
RUN_DIR=
DATA_DIR=
WORK=
DRIVER_OUT=
DRIVER_ERR=
D_OUTCOME= D_KIND= D_ATTEMPTED=0 D_DONE=0
declare -A F=()
fact() { printf '%s' "${F[$1]:-}"; }

load() {    # key|value lines on stdin -> F. A later line overrides an earlier one.
    local k v
    while IFS='|' read -r k v; do
        if [ -n "$k" ]; then F["$k"]=$v; fi
    done
}

die() {     # 2 only before the transaction; afterwards nothing is certain: 53
    echo "SECTION 5 ERROR: $*" >&2
    echo "TRANSACTION_EXECUTED=$TRANSACTION_EXECUTED"
    if [ "$TRANSACTION_EXECUTED" = yes ]; then
        echo "TRANSACTION_COMMITTED=unknown"
    else
        echo "TRANSACTION_COMMITTED=no"
    fi
    echo "VACUUM_EXECUTED=$VACUUM_EXECUTED"
    if [ "${F[prebackup_ok]:-}" = yes ]; then echo "PRE_RESTORE_BACKUP=${F[prebackup_folder]}"
    else echo "PRE_RESTORE_BACKUP=none"; fi
    if [ "$TRANSACTION_EXECUTED" = yes ]; then
        echo "RESULT=53"
        exit 53
    fi
    echo "RESULT=2"
    exit 2
}

cleanup() { # only the folders this run created, each re-checked before removal
    local dir
    for dir in "${CREATED[@]+"${CREATED[@]}"}"; do
        if [ -n "$FACTS_FILE" ] && [ "$dir" = "$DATA_DIR" ] && [ "${F[test_keep_data]:-}" = yes ]; then
            continue                             # (test) a rehearsal runs the real driver on it
        fi
        case "$dir" in
            /?*/fd_section5_data_[0-9]*Z|/?*/fd_section5_work_[0-9]*Z)
                if [ -d "$dir" ] && [ ! -L "$dir" ]; then rm -rf -- "${dir:?}"; fi ;;
        esac
    done
}
trap cleanup EXIT

if [ -n "$FACTS_FILE" ]; then
    [ "$(id -u)" != 0 ] || usage "--facts is a test mode and never runs as root"
    [ -r "$FACTS_FILE" ] || usage "cannot read the facts file $FACTS_FILE"
    load < "$FACTS_FILE"
    STORE=$(fact test_store)
    case "$STORE" in /?*) ;; *) usage "the facts name no absolute test_store" ;; esac
    [ "$STORE" != /var/backups/finance-dashboard ] || usage "a test never reads the real backup store"
    TMP_ROOT=$(fact test_tmp)
    case "$TMP_ROOT" in /?*) ;; *) usage "the facts name no absolute test_tmp" ;; esac
else
    [ "$(id -u)" = 0 ] || usage "run with sudo: the backup store is root's"
fi
cd /

q() {       # one read-only SQL file through the local socket -> key|value lines
    sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on' \
        psql -X -At -F '|' -v ON_ERROR_STOP=1 \
             -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" -f "$1"
}

q_sql() {   # one read-only statement through the local socket -> its rows
    sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on' \
        psql -X -At -v ON_ERROR_STOP=1 \
             -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" -c "$1"
}

hash_of() { sha256sum "$1" | awk '{print $1}'; }

pin_ok() { [ "$(fact "file_sha:$1")" = "${PIN[$1]}" ]; }

meta() {    # path -> uid:mode:kind (a link is reported as a link), or "missing"
    local info kind
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then echo missing; return 0; fi
    info=$(stat -c '%u:%a:%F' "$1")
    case "${info#*:*:}" in
        directory)                           kind=d ;;
        "regular file"|"regular empty file") kind=f ;;
        "symbolic link")                     kind=l ;;
        *)                                   kind=o ;;
    esac
    printf '%s:%s\n' "$(cut -d: -f1,2 <<<"$info")" "$kind"
}

fp_norm() { # fingerprint JSON -> "valid|<canonical JSON>|<postmaster_start>" or "invalid||"
    python3 - "$1" <<'PY'
import json, sys
keys = ("uuid", "postmaster_start", "max_aml_id",
        "aml_n_tup_ins", "aml_n_tup_upd", "aml_n_tup_del")
try:
    fp = json.loads(sys.argv[1])
except ValueError:
    fp = None
if isinstance(fp, dict) and all(isinstance(fp.get(k), str) and fp.get(k) for k in keys):
    print("valid|" + json.dumps({k: fp[k] for k in keys}, sort_keys=True, separators=(",", ":"))
          + "|" + fp["postmaster_start"])
else:
    print("invalid||")
PY
}

env_facts() {
    F[hostname]=$(hostname)
    F[odoo_service]=$(systemctl is-active "$ODOO_SERVICE" 2>/dev/null || true)
    F[odoo_processes]=$(pgrep -fc -- "$ODOO_BIN" || true)
}

file_facts() {   # sha256 of every pinned file, and what postgres can read
    local key path
    for key in "${PIN_KEYS[@]}"; do
        path="$HERE/$key"
        if [ -f "$path" ]; then F["file_sha:$key"]=$(hash_of "$path"); else F["file_sha:$key"]=missing; fi
    done
    for key in "${DRIVER_KEYS[@]}"; do
        if sudo -u postgres test -r "$HERE/$key"; then F["pg_reads:$key"]=true; else F["pg_reads:$key"]=false; fi
    done
}

folder_facts() { # who owns the backup folder, its record and the register
    F[backup_meta]=$(meta "$BACKUP")
    F[record_meta]=$(meta "$BACKUP/record.json")
    F[register_meta]=$(meta "$STORE/register.tsv")
}

record_facts() { # the record, parsed as data; its own SHA-256
    local out keys tables
    if [ ! -f "$BACKUP/record.json" ] || [ -L "$BACKUP/record.json" ]; then
        F[rec_parse]=missing; return 0
    fi
    F[record_sha]=$(hash_of "$BACKUP/record.json")
    keys=$(IFS=,; printf '%s' "${RECORD_TOOL_KEYS[*]}")
    tables=$(IFS=,; printf '%s' "${TABLES[*]}")
    out=$(python3 - "$BACKUP/record.json" "$keys" "$tables" <<'PY'
import json, sys
path, tool_keys, tables = sys.argv[1], sys.argv[2].split(","), sys.argv[3].split(",")
fp_keys = ("uuid", "postmaster_start", "max_aml_id",
           "aml_n_tup_ins", "aml_n_tup_upd", "aml_n_tup_del")

def emit(key, value):
    text = "" if value is None else str(value)
    print(key + "|" + text.replace("\n", " ").replace("|", "/"))

try:
    with open(path, "rb") as fh:
        rec = json.loads(fh.read().decode("utf-8"))
    if not isinstance(rec, dict):
        raise ValueError("not a JSON object")
    emit("rec_version", rec.get("record_version"))
    emit("rec_test", json.dumps(rec.get("test")))
    emit("rec_host", rec.get("host"))
    emit("rec_database", rec.get("database"))
    emit("rec_restorable", json.dumps(rec.get("restorable")))
    before = rec.get("assessment_before") or {}
    emit("rec_before_exit", before.get("exit"))
    emit("rec_before_verdict", before.get("verdict"))
    fp = rec.get("fingerprint")
    ok = isinstance(fp, dict) and all(isinstance(fp.get(k), str) and fp.get(k) for k in fp_keys)
    emit("rec_fp_valid", "true" if ok else "false")
    if ok:
        emit("rec_fp", json.dumps({k: fp[k] for k in fp_keys}, sort_keys=True, separators=(",", ":")))
        emit("rec_fp_uuid", fp["uuid"])
    emit("rec_stamp", rec.get("layer_refresh_time"))
    archive = rec.get("archive") or {}
    emit("rec_archive_file", archive.get("file"))
    emit("rec_archive_bytes", archive.get("bytes"))
    emit("rec_archive_sha", archive.get("sha256"))
    found = rec.get("tables") or {}
    emit("rec_tables", ",".join(found))
    for t in tables:
        entry = found.get(t) or {}
        emit("rec_rows:" + t, entry.get("rows"))
        emit("rec_cols:" + t, entry.get("columns"))
        emit("rec_sha:" + t, entry.get("copy_sha256"))
    tools = rec.get("tools") or {}
    for key in tool_keys:
        emit("rec_tool:" + key, tools.get(key))
    emit("rec_parse", "ok")
except Exception as exc:
    emit("rec_parse", "unreadable: " + type(exc).__name__)
PY
    ) || out="rec_parse|unreadable: python3 failed"
    load <<<"$out"
}

register_facts() { # the register line for this folder
    local name line result restorable archive record
    name=$(basename "$BACKUP")
    if [ ! -f "$STORE/register.tsv" ]; then F[reg_lines]=0; return 0; fi
    F[reg_lines]=$(awk -F'\t' -v n="$name" '$1 !~ /^#/ && $2 == n {c++} END {print c + 0}' "$STORE/register.tsv")
    line=$(awk -F'\t' -v n="$name" '$1 !~ /^#/ && $2 == n {print; exit}' "$STORE/register.tsv")
    IFS=$'\t' read -r _ _ result restorable archive record <<<"$line"
    F[reg_result]=$result F[reg_restorable]=$restorable F[reg_archive_sha]=$archive F[reg_record_sha]=$record
}

archive_facts() {  # the archive the record names: owner, size, SHA-256
    local file
    file=$(fact rec_archive_file)
    if ! [[ $file =~ $RE_ARCHIVE ]]; then F[archive_meta]=badname; return 0; fi
    if [ -z "$FACTS_FILE" ]; then F[archive_meta]=$(meta "$BACKUP/$file"); fi
    if [ -f "$BACKUP/$file" ] && [ ! -L "$BACKUP/$file" ]; then
        F[archive_sha]=$(hash_of "$BACKUP/$file")
        F[archive_bytes]=$(wc -c < "$BACKUP/$file" | tr -d ' ')
    fi
}

extract_facts() {  # the archive itself, through pg_restore: its scope, then each table's rows
    local archive listing want got_table got_data t
    archive="$BACKUP/$(fact rec_archive_file)"
    if ! listing=$(pg_restore -l "$archive" 2>/dev/null); then
        F[scope_ok]=false; F[scope_detail]="pg_restore -l could not read it"; return 0
    fi
    want=$(printf 'public.%s\n' "${TABLES[@]}" | LC_ALL=C sort)
    got_table=$(awk '$1 !~ /^;/ && $4 == "TABLE" && $5 != "DATA" {print $5 "." $6}' <<<"$listing" | LC_ALL=C sort)
    got_data=$(awk '$1 !~ /^;/ && $4 == "TABLE" && $5 == "DATA" {print $6 "." $7}' <<<"$listing" | LC_ALL=C sort)
    if [ "$got_table" = "$want" ] && [ "$got_data" = "$want" ]; then
        F[scope_ok]=true
    else
        F[scope_ok]=false
        F[scope_detail]="tables [$(paste -sd' ' - <<<"$got_table")] data [$(paste -sd' ' - <<<"$got_data")]"
    fi
    for t in "${TABLES[@]}"; do
        if ! pg_restore --data-only -t "$t" -f "${WORK:?}/${t:?}.sql" "$archive" 2>/dev/null; then
            F["ext_ok:$t"]=false; continue
        fi
        F["ext_cols:$t"]=$(awk '/^COPY / {sub(/^COPY [^ ]+ /, ""); sub(/ FROM stdin;$/, ""); print; exit}' "$WORK/$t.sql")
        awk 'f && /^\\\.$/ {f = 0; next} f {print} /^COPY / {f = 1}' "$WORK/$t.sql" > "$WORK/$t.copy"
        rm -f -- "${WORK:?}/${t:?}.sql"
        F["ext_rows:$t"]=$(wc -l < "$WORK/$t.copy" | tr -d ' ')
        F["ext_sha:$t"]=$(LC_ALL=C sort "$WORK/$t.copy" | sha256sum | awk '{print $1}')
        F["ext_maxid:$t"]=$(awk -F'\t' 'NR == 1 || $1 + 0 > m {m = $1 + 0} END {if (NR) print m}' "$WORK/$t.copy")
        F["ext_ok:$t"]=true
    done
}

assess() {      # $1 = pre|final : a fresh Section 2 assessment; its code, verdict, fingerprint
    local out code=0 norm valid canon started
    if [ -z "$FACTS_FILE" ]; then
        out=$(bash "$HERE/10_assess.sh" --state-file "$STATE_FILE" 2>&1) || code=$?
        F["$1_assess_code"]=$code
        F["$1_assess_verdict"]=$(awk -F= '/^VERDICT=/ {v = $2} END {print v}' <<<"$out")
        F["$1_fp_json"]=$(awk '/^FINGERPRINT_JSON=/ {sub(/^FINGERPRINT_JSON=/, ""); v = $0} END {print v}' <<<"$out")
    fi
    norm=$(fp_norm "$(fact "$1_fp_json")")
    IFS='|' read -r valid canon started <<<"$norm"
    F["$1_fp_valid"]=$valid F["$1_fp"]=$canon F["$1_fp_postmaster_start"]=$started
}

layer_facts() {  # $1 = pre|post : module state + layer facts (10b); a failure is recorded
    local out k v
    if ! out=$(q "$HERE/10b_assess_facts.sql" 2>/dev/null); then
        F["$1_module_state"]=unknown; return 0
    fi
    while IFS='|' read -r k v; do
        if [ -n "$k" ]; then F["$1_$k"]=$v; fi
    done <<<"$out"
}

sequence_sql() { # per table: name|sequence|last_value|max(id) - one read-only statement
    local t sql=
    for t in "${TABLES[@]}"; do
        sql+="${sql:+ UNION ALL }SELECT '$t', COALESCE(pg_get_serial_sequence('public.$t', 'id'), ''), COALESCE((SELECT s.last_value FROM pg_sequences s WHERE quote_ident(s.schemaname) || '.' || quote_ident(s.sequencename) = pg_get_serial_sequence('public.$t', 'id'))::text, ''), COALESCE((SELECT max(id) FROM public.$t)::text, '')"
    done
    printf '%s' "$sql"
}

read_layer() {   # $1 = pre|post : the CURRENT layer from a fresh connection, read-only
    local p=$1 out t name seq last maxid
    if [ -n "$FACTS_FILE" ]; then return 0; fi    # (test) the facts hold it
    layer_facts "$p"
    if out=$(q_sql "$STAMP_SQL" 2>/dev/null); then F["${p}_stamp"]=$out; F["${p}_stamp_ok"]=true
    else F["${p}_stamp_ok"]=false; fi
    if out=$(q "$HERE/06c_validate_cross_table.sql" 2>/dev/null); then
        F["${p}_06c_rows"]=$(awk 'NF {n++} END {print n + 0}' <<<"$out")
        F["${p}_06c_pass"]=$(awk -F'|' '$5 == "PASS" {n++} END {print n + 0}' <<<"$out")
    else
        F["${p}_06c_rows"]=0; F["${p}_06c_pass"]=0
    fi
    for t in "${TABLES[@]}"; do
        if sudo -u postgres env PGOPTIONS="$COPY_OPTIONS" psql -X -q -v ON_ERROR_STOP=1 \
                -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" -c "COPY public.$t TO STDOUT" \
                > "$WORK/$p.$t.copy" 2>/dev/null; then
            F["${p}_hrows:$t"]=$(wc -l < "$WORK/$p.$t.copy" | tr -d ' ')
            F["${p}_sha:$t"]=$(LC_ALL=C sort "$WORK/$p.$t.copy" | sha256sum | awk '{print $1}')
        else
            F["${p}_hrows:$t"]=
            F["${p}_sha:$t"]=unreadable
        fi
        rm -f -- "${WORK:?}/${p:?}.${t:?}.copy"
    done
    if out=$(q_sql "$(sequence_sql)" 2>/dev/null); then
        while IFS='|' read -r name seq last maxid; do
            if [ -z "$name" ]; then continue; fi
            F["${p}_seqname:$name"]=$seq F["${p}_seq:$name"]=$last F["${p}_maxid:$name"]=$maxid
        done <<<"$out"
        F["${p}_seq_ok"]=true
    else
        F["${p}_seq_ok"]=false
    fi
}

live_column_facts() {   # each table's live columns, in COPY's "(a, b, ...)" form
    local t out
    if [ -n "$FACTS_FILE" ]; then return 0; fi
    for t in "${TABLES[@]}"; do
        if out=$(q_sql "SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$t'" 2>/dev/null); then
            F["live_cols:$t"]="($out)"
        else
            F["live_cols:$t"]=unreadable
        fi
    done
}

check_meta() {  # label, meta, kind, mode -> a problem line, or nothing
    local label=$1 got=$2 kind=$3 mode=$4
    if [ "$got" = missing ]; then echo "$label does not exist"; return 0; fi
    if [ "$got" != "0:$mode:$kind" ]; then
        echo "$label is uid:mode:kind $got, expected 0:$mode:$kind (root's, mode $mode, no link)"
    fi
}

decide_pre() {   # facts -> REFUSE[]. Reads nothing else.
    local key sha t line code test_want
    for key in "${PIN_KEYS[@]}"; do
        sha=$(fact "file_sha:$key")
        if [ "$sha" = missing ] || [ -z "$sha" ]; then REFUSE+=("$key is missing")
        elif ! pin_ok "$key"; then REFUSE+=("$key does not match its approved hash (found ${sha:0:12}...)"); fi
    done
    for key in "${DRIVER_KEYS[@]}"; do
        [ "$(fact "pg_reads:$key")" = true ] \
            || REFUSE+=("postgres cannot read $key - the driver opens it itself")
    done
    case "$(fact odoo_service)" in
        inactive|failed) ;;
        *) REFUSE+=("Odoo service is '$(fact odoo_service)' - stop it first; this script never stops or starts Odoo") ;;
    esac
    [ "$(fact odoo_processes)" = 0 ] \
        || REFUSE+=("$(fact odoo_processes) Odoo process(es) still running from $ODOO_BIN")
    # the backup: where it is, who owns it, what it says
    [ "$(dirname "$BACKUP")" = "$STORE" ] \
        || REFUSE+=("$BACKUP is not directly in the backup store $STORE")
    [[ $(basename "$BACKUP") =~ $RE_FOLDER ]] \
        || REFUSE+=("$(basename "$BACKUP") is not an fd_backup_<UTC> folder - only verified backups are restored")
    while IFS= read -r line; do if [ -n "$line" ]; then REFUSE+=("$line"); fi; done <<<"$(
        check_meta "the backup folder" "$(fact backup_meta)" d 700
        check_meta "record.json" "$(fact record_meta)" f 400
        check_meta "the register" "$(fact register_meta)" f 600
        if [ "$(fact archive_meta)" = badname ]; then echo "the record names no valid archive file"
        else check_meta "the archive" "$(fact archive_meta)" f 400; fi)"
    if [ "$(fact rec_parse)" != ok ]; then
        REFUSE+=("record.json is not a readable record ($(fact rec_parse))")
        return 0
    fi
    # a real restore takes only real records; a test (--facts) takes only test records
    if [ -n "$FACTS_FILE" ]; then test_want=true; else test_want=false; fi
    [ "$(fact rec_version)" = 1 ] || REFUSE+=("record_version is '$(fact rec_version)', expected 1")
    [ "$(fact rec_test)" = "$test_want" ] \
        || REFUSE+=("the record's test flag is $(fact rec_test), expected $test_want for this kind of run")
    [ "$(fact rec_host)" = "$(fact hostname)" ] && [ "$(fact hostname)" = "$EXPECTED_HOSTNAME" ] \
        || REFUSE+=("the record is from host '$(fact rec_host)', this is '$(fact hostname)' (expected $EXPECTED_HOSTNAME)")
    [ "$(fact rec_database)" = "$DATABASE" ] \
        || REFUSE+=("the record is for database '$(fact rec_database)', expected $DATABASE")
    [ "$(fact rec_restorable)" = true ] \
        || REFUSE+=("the record says this backup is NOT restorable (evidence only)")
    [ "$(fact rec_before_exit)" = 0 ] && [ "$(fact rec_before_verdict)" = "NOTHING TO DO" ] \
        || REFUSE+=("the assessment at backup time was exit $(fact rec_before_exit) '$(fact rec_before_verdict)', not 0 NOTHING TO DO")
    if [ "$(fact rec_fp_valid)" != true ]; then
        REFUSE+=("the record holds no complete fingerprint")
    elif [ "$(fact rec_fp_uuid)" != "$EXPECTED_UUID" ]; then
        REFUSE+=("the record's uuid is '$(fact rec_fp_uuid)', expected $EXPECTED_UUID")
    fi
    [[ $(fact rec_stamp) =~ $RE_STAMP ]] \
        || REFUSE+=("the record's refresh time '$(fact rec_stamp)' is not a valid refresh time")
    [ "$(fact rec_tables)" = "$(IFS=,; printf '%s' "${TABLES[*]}")" ] \
        || REFUSE+=("the record lists the tables [$(fact rec_tables)], not exactly the five")
    for key in "${RECORD_TOOL_KEYS[@]}"; do
        [ "$(fact "rec_tool:$key")" = "${PIN[$key]}" ] \
            || REFUSE+=("the record was made with $key '$(fact "rec_tool:$key" | cut -c1-12)', not the pinned ${PIN[$key]:0:12}... - a record of another tool version is not used")
    done
    # the register: the one line written when the backup was verified
    if [ "$(fact reg_lines)" != 1 ]; then
        REFUSE+=("the register has $(fact reg_lines) line(s) for $(basename "$BACKUP"), expected exactly 1")
    else
        [ "$(fact reg_result)" = 0 ] && [ "$(fact reg_restorable)" = yes ] \
            || REFUSE+=("the register line says result $(fact reg_result), restorable $(fact reg_restorable)")
        [ "$(fact reg_record_sha)" = "$(fact record_sha)" ] \
            || REFUSE+=("record.json's SHA-256 $(fact record_sha) differs from its register line $(fact reg_record_sha) - the record changed after the backup")
        [ "$(fact reg_archive_sha)" = "$(fact rec_archive_sha)" ] \
            || REFUSE+=("the register line's archive SHA-256 differs from the record's")
    fi
    # the archive: the bytes the record describes
    [ "$(fact archive_sha)" = "$(fact rec_archive_sha)" ] \
        || REFUSE+=("the archive's SHA-256 is '$(fact archive_sha)', the record says $(fact rec_archive_sha) - the archive changed")
    [ "$(fact archive_bytes)" = "$(fact rec_archive_bytes)" ] \
        || REFUSE+=("the archive is '$(fact archive_bytes)' bytes, the record says $(fact rec_archive_bytes)")
    if [ "$LIVE" = 1 ]; then
        [ "$CONFIRM_ARCHIVE" = "$(fact archive_sha)" ] \
            || REFUSE+=("--confirm-archive does not match this archive's SHA-256 - type it from the vault entry of this backup")
        [ "$CONFIRM_RECORD" = "$(fact record_sha)" ] \
            || REFUSE+=("--confirm-record does not match this record's SHA-256 - type it from the vault entry of this backup")   # [B]
    fi
    [ "$(fact scope_ok)" = true ] \
        || REFUSE+=("the archive does not hold exactly the five tables: $(fact scope_detail)")
    for t in "${TABLES[@]}"; do
        if [ "$(fact "ext_ok:$t")" != true ]; then REFUSE+=("$t: its data could not be read from the archive"); continue; fi
        [ "$(fact "ext_cols:$t")" = "$(fact "rec_cols:$t")" ] \
            || REFUSE+=("$t: the archive's columns differ from the record's")
        [ "$(fact "ext_rows:$t")" = "$(fact "rec_rows:$t")" ] && [ "$(fact "ext_sha:$t")" = "$(fact "rec_sha:$t")" ] \
            || REFUSE+=("$t: the archive holds $(fact "ext_rows:$t") rows $(fact "ext_sha:$t" | cut -c1-12)..., the record says $(fact "rec_rows:$t") rows $(fact "rec_sha:$t" | cut -c1-12)...")
    done
    # now: the database, as a fresh assessment and a fresh read see it
    code=$(fact pre_assess_code)
    case "$code" in
        0|10) ;;
        11) REFUSE+=("the assessment says INSTALL + REFRESH - the module is not installed") ;;
        20) REFUSE+=("the assessment says STOP: wrong target - not the expected reporting environment") ;;
        21) REFUSE+=("the assessment says STOP: pending modules - investigate manually") ;;
        22) REFUSE+=("the assessment says STOP: layer anomaly - investigate; a restore is not assumed safe") ;;
        2)  REFUSE+=("the Section 2 assessment did not complete - the environment cannot be confirmed") ;;
        not-run) REFUSE+=("the Section 2 assessment was not run: its own files do not match their approved hashes") ;;
        *)  REFUSE+=("the Section 2 assessment returned unexpected exit code '$code'") ;;
    esac
    if [ "$code" = 0 ] || [ "$code" = 10 ]; then
        [ "$(fact pre_module_state)" = installed ] \
            || REFUSE+=("the module state is '$(fact pre_module_state)', expected installed")
        if [ "$(fact pre_fp_valid)" != valid ]; then
            REFUSE+=("the assessment printed no complete fingerprint")
        elif [ "$(fact pre_fp)" != "$(fact rec_fp)" ]; then
            REFUSE+=("the ledger fingerprint now is $(fact pre_fp), the record's is $(fact rec_fp) - this backup belongs to another ledger state; fix the cause and rebuild (Section 4)")
        fi
        for t in "${TABLES[@]}"; do
            [ "$(fact "live_cols:$t")" = "$(fact "rec_cols:$t")" ] \
                || REFUSE+=("$t: the live columns $(fact "live_cols:$t") differ from the archive's $(fact "rec_cols:$t") - the schema changed")
            [ "$(fact "pre_sha:$t")" != unreadable ] && [ -n "$(fact "pre_sha:$t")" ] \
                || REFUSE+=("$t: the current rows could not be read")
        done
        [ "$(fact pre_seq_ok)" = true ] || REFUSE+=("the id sequences could not be read")
        [ "$(fact pre_stamp_ok)" = true ] || REFUSE+=("the current refresh time could not be read")
    fi
}

predict() {     # per table: would its sequence stay at or above the restored ids?
    local t last maxid
    for t in "${TABLES[@]}"; do
        last=$(fact "pre_seq:$t") maxid=$(fact "ext_maxid:$t")
        if [ -z "$maxid" ]; then F["predict:$t"]=OK
        elif [ -n "$last" ] && [[ $last =~ ^[0-9]+$ ]] && [[ $maxid =~ ^[0-9]+$ ]] && [ "$last" -ge "$maxid" ]; then F["predict:$t"]=OK
        else F["predict:$t"]=BEHIND; fi
    done
}

prebackup() {   # --live: 09a backs up the CURRENT layer, verified, before any write
    local out rc=0
    if [ -n "$FACTS_FILE" ]; then
        out=$(cat "$(fact test_prebackup_output)"); rc=$(fact test_prebackup_rc)
    else
        out=$(bash "$HERE/09a_backup_with_record.sh" --state-file "$STATE_FILE" 2>&1) || rc=$?
        printf '%s\n' "$out" > "$RUN_DIR/prebackup.txt"
    fi
    F[prebackup_rc]=$rc
    F[prebackup_result]=$(awk -F= '/^BACKUP_RESULT=/ {v = $2} END {print v}' <<<"$out")
    F[prebackup_folder]=$(awk '/^BACKUP_FOLDER=/ {sub(/^BACKUP_FOLDER=/, ""); v = $0} END {print v}' <<<"$out")
    F[prebackup_archive]=$(awk -F= '/^BACKUP_ARCHIVE_SHA256=/ {v = $2} END {print v}' <<<"$out")
    F[prebackup_record]=$(awk -F= '/^BACKUP_RECORD_SHA256=/ {v = $2} END {print v}' <<<"$out")
    F[prebackup_restorable]=$(awk -F= '/^BACKUP_RESTORABLE=/ {v = $2} END {print v}' <<<"$out")
}

decide_prebackup() {   # -> REFUSE[]
    local rc result
    rc=$(fact prebackup_rc) result=$(fact prebackup_result)
    if { [ "$rc" = 0 ] || [ "$rc" = 57 ]; } && [ "$result" = "$rc" ] \
       && [ -n "$(fact prebackup_folder)" ] && [[ $(fact prebackup_archive) =~ $RE_SHA ]] \
       && [[ $(fact prebackup_record) =~ $RE_SHA ]]; then
        F[prebackup_ok]=yes
        return 0
    fi
    REFUSE+=("the pre-restore backup of the current layer did not complete and verify (exit $rc, result '${result:-none}') - nothing was written; see its output")
}

decide_final() {      # --live, after the pre-restore backup: still the recorded ledger state?
    case "$(fact final_assess_code)" in
        0|10) ;;
        *) REFUSE+=("the assessment after the pre-restore backup says exit $(fact final_assess_code) '$(fact final_assess_verdict)'"); return 0 ;;
    esac
    [ "$(fact final_fp_valid)" = valid ] && [ "$(fact final_fp)" = "$(fact rec_fp)" ] \
        || REFUSE+=("the fingerprint changed during the pre-restore backup ($(fact final_fp)) - not the recorded ledger state any more")
}

prepare_data() {   # the folder the driver reads: the five data files + plan.json, postgres's
    local t
    DATA_DIR="$TMP_ROOT/fd_section5_data_$STAMP"
    mkdir -m 0700 "$DATA_DIR" || die "could not create $DATA_DIR - nothing was started"
    CREATED+=("$DATA_DIR")
    for t in "${TABLES[@]}"; do
        cp "$WORK/$t.copy" "$DATA_DIR/$t.copy" || die "could not stage $t's data - nothing was started"
    done
    python3 - "$BACKUP/record.json" "$DATA_DIR/plan.json" "$(fact record_sha)" "${TABLES[@]}" <<'PY' \
        || die "could not write the restore plan - nothing was started"
import json, sys
record, target, record_sha, tables = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
with open(record, "rb") as fh:
    rec = json.loads(fh.read().decode("utf-8"))
plan = {"tables": {}, "layer_refresh_time": rec["layer_refresh_time"],
        "archive_sha256": rec["archive"]["sha256"], "record_sha256": record_sha}
for t in tables:
    entry = rec["tables"][t]
    plan["tables"][t] = {"columns": [c.strip() for c in entry["columns"].strip("()").split(",")],
                         "rows": entry["rows"], "copy_sha256": entry["copy_sha256"]}
with open(target, "w") as fh:
    fh.write(json.dumps(plan, indent=1) + "\n")
PY
    chmod 0400 "$DATA_DIR"/*
    if [ -z "$FACTS_FILE" ]; then
        chown -R postgres:postgres "$DATA_DIR" || die "could not hand $DATA_DIR to postgres - nothing was started"
    fi
    F[plan_sha]=$(hash_of "$DATA_DIR/plan.json")
}

postmaster_for_driver() {
    if [ "$LIVE" = 1 ]; then fact final_fp_postmaster_start; else fact pre_fp_postmaster_start; fi
}

build_cmd() {    # the command, built once; shown from and run from this same array
    local key pins=()
    for key in "${DRIVER_KEYS[@]}"; do pins+=("$key=${PIN[$key]}"); done
    CMD=(sudo -u postgres env
         "FD5_MODE=$TXN_MODE"
         "FD5_SOCKET_DIR=$SOCKET_DIR"
         "FD5_PORT=$SOCKET_PORT"
         "FD5_DATABASE=$DATABASE"
         "FD5_EXPECTED_UUID=$EXPECTED_UUID"
         "FD5_PRE_POSTMASTER_START=$(postmaster_for_driver)"
         "FD5_LOCK_TIMEOUT=$LOCK_TIMEOUT"
         "FD5_DIR=$HERE"
         "FD5_PINS=$(IFS=';'; printf '%s' "${pins[*]}")"
         "FD5_DATA_DIR=${DATA_DIR:-<made at run time>}"
         "FD5_PLAN_SHA256=${F[plan_sha]:-<computed at run time>}"
         python3 -P -)
}

show_cmd() {
    local word
    printf 'cd / && '
    for word in "${CMD[@]}"; do
        case "$word" in
            FD5_PINS=*) printf 'FD5_PINS=<the %s driver pins above> ' "${#DRIVER_KEYS[@]}" ;;
            *) printf '%q ' "$word" ;;
        esac
    done
    printf '< %q' "$HERE/09b_restore_transaction.py"
}

run_transaction() {   # THE ONLY WRITE PATH. Runs once; never retried.
    if [ -n "$FACTS_FILE" ]; then
        TRANSACTION_EXECUTED=yes
        DRIVER_OUT=$(fact test_driver_output)
        return "${F[test_python_rc]:-0}"
    fi
    : > "$DRIVER_OUT" || die "cannot write $DRIVER_OUT - nothing was started"
    : > "$DRIVER_ERR" || die "cannot write $DRIVER_ERR - nothing was started"
    TRANSACTION_EXECUTED=yes
    ( cd / && "${CMD[@]}" < "$HERE/09b_restore_transaction.py" ) > "$DRIVER_OUT" 2> "$DRIVER_ERR"
}

parse_driver() {  # the FD5 lines -> D_*. Reads the driver output only.
    local file=$1
    D_OUTCOME=$(awk -F'|' '$1 == "FD5" && $2 == "outcome" {o = $0} END {print o}' "$file")
    D_ATTEMPTED=$(awk -F'|' '$1 == "FD5" && $2 == "commit" && $3 == "ATTEMPTED" {n++} END {print n + 0}' "$file")
    D_DONE=$(awk -F'|' '$1 == "FD5" && $2 == "commit" && $3 == "DONE" {n++} END {print n + 0}' "$file")
    case "$D_OUTCOME" in
        "FD5|outcome|COMMITTED")              D_KIND=committed ;;
        "FD5|outcome|UNKNOWN"*)               D_KIND=unknown ;;
        "FD5|outcome|ROLLED_BACK|test|"*)     D_KIND=test ;;
        "FD5|outcome|ROLLED_BACK|gate|"*)     D_KIND=gate ;;
        "FD5|outcome|ROLLED_BACK|refused|"*)  D_KIND=refused ;;
        "FD5|outcome|ROLLED_BACK|error|"*)    D_KIND=error ;;
        "")                                   D_KIND=none ;;
        *)                                    D_KIND=other ;;
    esac
}

test_mode() { [ "$TXN_MODE" != live ]; }

same_as() {     # $1 = pre|rec : every table and the refresh time now equal that
    local t want_rows want_sha want_stamp
    for t in "${TABLES[@]}"; do
        if [ "$1" = rec ]; then want_rows=$(fact "rec_rows:$t") want_sha=$(fact "rec_sha:$t")
        else want_rows=$(fact "pre_hrows:$t") want_sha=$(fact "pre_sha:$t"); fi
        [ "$(fact "post_sha:$t")" = "$want_sha" ] && [ "$(fact "post_hrows:$t")" = "$want_rows" ] || return 1
    done
    if [ "$1" = rec ]; then want_stamp=$(fact rec_stamp); else want_stamp=$(fact pre_stamp); fi
    [ "$(fact post_stamp_ok)" = true ] && [ "$(fact post_stamp)" = "$want_stamp" ]
}

post_readable() {
    local t
    [ "$(fact post_stamp_ok)" = true ] && [ "$(fact post_seq_ok)" = true ] || return 1
    for t in "${TABLES[@]}"; do
        [ "$(fact "post_sha:$t")" != unreadable ] && [ -n "$(fact "post_sha:$t")" ] || return 1
    done
}

sequences_unchanged() {
    local t
    for t in "${TABLES[@]}"; do
        [ "$(fact "post_seq:$t")" = "$(fact "pre_seq:$t")" ] || return 1
    done
}

confirm_rolled_back() {   # a rolled-back outcome: the fresh read must show the layer as before
    local code=$1
    if ! post_readable; then
        if [ "$code" = 0 ]; then
            CODE=51
            REASONS+=("the driver rolled back and never called commit(), but a fresh connection could not confirm the layer is unchanged - the test is not proven; take the 12c snapshot")
        else
            REASONS+=("a fresh connection could not confirm the layer is unchanged (the driver never called commit())")
        fi
        return 0
    fi
    if same_as pre && sequences_unchanged \
       && [ "$(fact post_postmaster_start)" = "$(fact pre_postmaster_start)" ]; then
        REASONS+=("confirmed from a fresh connection: every table, the refresh time and every id sequence are exactly as before")
    else
        CODE=53 COMMITTED=unknown FRESH=yes
        REASONS+=("a fresh connection does NOT show the layer as it was before this rolled-back run - something changed it; nothing can be guaranteed")
    fi
}

decide_post() {  # facts + driver lines -> CODE, REASONS, COMMITTED, NEED_VACUUM, FRESH
    local bad=() t
    if test_mode && { [ "$D_KIND" = committed ] || [ "$D_ATTEMPTED" -gt 0 ] || [ "$D_DONE" -gt 0 ]; }; then
        CODE=53 COMMITTED=unknown FRESH=yes
        REASONS=("a ROLLBACK-ONLY run reported a commit attempt - impossible by design; check the layer before anything else")
        return
    fi
    case "$D_KIND" in
        test)
            COMMITTED=no
            if ! test_mode; then
                CODE=51 REASONS=("the driver ran as a test although --live was requested - nothing was committed")
            elif [ "$PY_RC" != 0 ]; then
                CODE=51 REASONS=("every check passed and the transaction was rolled back, but python exited $PY_RC - read driver.err before relying on this run")
            else
                CODE=0 REASONS=("every check passed; the transaction was rolled back as a test always is - nothing was committed")
            fi
            confirm_rolled_back "$CODE" ;;
        gate)
            CODE=52 COMMITTED=no
            REASONS=("rolled back, nothing committed: ${D_OUTCOME#FD5|outcome|ROLLED_BACK|gate|}")
            confirm_rolled_back 52 ;;
        refused|error)
            CODE=51 COMMITTED=no
            REASONS=("rolled back, nothing committed: ${D_OUTCOME#FD5|outcome|ROLLED_BACK|}")
            confirm_rolled_back 51 ;;
        none|other)
            if [ "$D_ATTEMPTED" -gt 0 ]; then
                CODE=53 COMMITTED=unknown FRESH=yes
                REASONS=("python ended after attempting the commit, without reporting its result (exit $PY_RC)")
            else
                CODE=51 COMMITTED=no
                REASONS=("python ended without an outcome (exit $PY_RC) and never attempted a commit - PostgreSQL discarded whatever it had started; read driver.err")
                confirm_rolled_back 51
            fi ;;
        unknown)
            CODE=53 COMMITTED=unknown FRESH=yes
            REASONS=("the commit raised an error: ${D_OUTCOME#FD5|outcome|UNKNOWN|}") ;;
        committed)
            COMMITTED=yes
            [ "$PY_RC" = 0 ] || bad+=("python exited $PY_RC after reporting the commit")
            post_readable || bad+=("the restored layer could not be read back from a fresh connection")
            [ "$(fact post_postmaster_start)" = "$(fact pre_postmaster_start)" ] \
                || bad+=("cluster start time is now '$(fact post_postmaster_start)', it was '$(fact pre_postmaster_start)'")
            for t in "${TABLES[@]}"; do
                [ "$(fact "post_sha:$t")" = "$(fact "rec_sha:$t")" ] && [ "$(fact "post_hrows:$t")" = "$(fact "rec_rows:$t")" ] \
                    || bad+=("$t: a fresh connection reads $(fact "post_hrows:$t") rows $(fact "post_sha:$t" | cut -c1-12)..., the record says $(fact "rec_rows:$t") rows $(fact "rec_sha:$t" | cut -c1-12)...")
            done
            [ "$(fact post_stamp)" = "$(fact rec_stamp)" ] \
                || bad+=("refresh time from a fresh connection is '$(fact post_stamp)', the record says '$(fact rec_stamp)'")
            [ "$(fact post_module_state)" = installed ] \
                || bad+=("module state is '$(fact post_module_state)', expected installed")
            [ "$(fact post_provisioned_by)" = orm ] && [ "$(fact post_schema_money_bad)" = 0 ] \
                && [ "$(fact post_schema_aging_bad)" = 0 ] && [ -z "$(fact post_schema_index_missing)" ] \
                && [ -z "$(fact post_schema_grain_missing)" ] \
                || bad+=("schema not clean after the commit")
            [ "$(fact post_06c_rows)" = 7 ] && [ "$(fact post_06c_pass)" = 7 ] \
                || bad+=("06c from a fresh connection: $(fact post_06c_pass)/$(fact post_06c_rows) PASS")
            if [ ${#bad[@]} -gt 0 ]; then
                CODE=53 FRESH=yes
                REASONS=("PostgreSQL confirmed the commit, but the fresh check does not agree:" "${bad[@]}")
                return
            fi
            CODE=0 NEED_VACUUM=yes
            REASONS=("committed, and confirmed from a fresh connection: every table's rows and SHA-256 equal the record, the refresh time, 06c 7/7, schema clean, the same cluster start")
            for t in "${TABLES[@]}"; do
                if [ -n "$(fact "post_maxid:$t")" ] && { ! [[ $(fact "post_seq:$t") =~ ^[0-9]+$ ]] \
                        || [ "$(fact "post_seq:$t")" -lt "$(fact "post_maxid:$t")" ]; }; then
                    CODE=54
                    REASONS+=("$t: its id sequence $(fact "post_seqname:$t") is at '$(fact "post_seq:$t")', below the restored max(id) $(fact "post_maxid:$t") - the next refresh would collide. With approval only, run: sudo -u postgres psql -X -h $SOCKET_DIR -p $SOCKET_PORT -d $DATABASE -c \"SELECT setval('$(fact "post_seqname:$t")', $(fact "post_maxid:$t"), true)\"")
                fi
            done
            REASONS+=("the layer is back to the build recorded at $(fact rec_stamp); fix whatever damaged it before relying on it again") ;;
    esac
}

fresh_state() {  # 53 only: which data a fresh connection sees now. Facts only.
    if [ "$(fact post_postmaster_start)" != "$(fact pre_postmaster_start)" ]; then
        REASONS+=("fresh connection: the cluster restarted (start time '$(fact pre_postmaster_start)' -> '$(fact post_postmaster_start)'); whatever is in place belongs to the restarted cluster - run the assessment")
    elif ! post_readable; then
        REASONS+=("fresh connection: the layer could not be read - run the assessment")
    elif same_as rec; then
        REASONS+=("fresh connection: the RESTORED data is in place (every table equals the record)")
    elif same_as pre; then
        REASONS+=("fresh connection: NOT restored - the previous data is in place (every table as before the run)")
    else
        REASONS+=("fresh connection: undetermined - the layer equals neither the record nor what was there before")
    fi
    if [ "$(fact prebackup_ok)" = yes ]; then
        REASONS+=("the verified pre-restore backup is $(fact prebackup_folder)")
    fi
}

do_vacuum() {    # after a VERIFIED commit only. Plain VACUUM (ANALYZE), never FULL.
    local args=() t
    if [ -n "$FACTS_FILE" ]; then return "${F[test_vacuum_rc]:-0}"; fi
    for t in "${TABLES[@]}"; do args+=(-c "VACUUM (ANALYZE) public.$t;"); done
    sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 \
        -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" "${args[@]}"
}

mode_text() {
    local text
    if [ -n "$FACTS_FILE" ]; then text=TEST; else text=LIVE; fi
    if [ "$DRY_RUN" = 1 ]; then text="$text, DRY RUN"; fi
    if [ "$LIVE" = 1 ]; then text="$text, REAL RESTORE (--live)"
    elif [ "$ROLLBACK_ONLY" = 1 ]; then text="$text, ROLLBACK-ONLY"
    else text="$text (pre-checks only)"; fi
    printf '%s' "$text"
}

short() { if [[ $1 =~ $RE_SHA ]]; then printf '%s...' "${1:0:12}"; else printf '%s' "${1:--}"; fi; }

report() {
    local key ok=0 t word line same
    for key in "${PIN_KEYS[@]}"; do if pin_ok "$key"; then ok=$((ok + 1)); fi; done
    echo "=== Finance Dashboard - Section 5: restore from a verified backup ==="
    echo "mode          : $(mode_text)"
    echo "files         : $ok/${#PIN_KEYS[@]} match their approved SHA-256"
    for key in "${PIN_KEYS[@]}"; do
        if ! pin_ok "$key"; then echo "    MISMATCH  $key  found=$(fact "file_sha:$key")"; fi
    done
    echo "odoo          : service=$(fact odoo_service) processes=$(fact odoo_processes)"
    echo "backup        : $BACKUP"
    echo "record        : sha256 $(fact record_sha)  restorable=$(fact rec_restorable)  register line(s)=$(fact reg_lines)"
    echo "archive       : $(fact rec_archive_file)  sha256 $(fact archive_sha)  $(fact archive_bytes) bytes"
    if [ "$LIVE" = 1 ]; then
        if [ "$CONFIRM_ARCHIVE" = "$(fact archive_sha)" ]; then same=MATCH; else same=DIFFERENT; fi
        line="archive $same"
        if [ "$CONFIRM_RECORD" = "$(fact record_sha)" ]; then same=MATCH; else same=DIFFERENT; fi   # [B]
        echo "confirmed     : $line  record $same"
    fi
    echo "assessment    : exit $(fact pre_assess_code) - $(fact pre_assess_verdict)  module=$(fact pre_module_state)"
    echo "fingerprint   : now      $(fact pre_fp)"
    echo "                recorded $(fact rec_fp)"
    echo "the layer     : now (fresh connection)           -> after a restore (the record)"
    for t in "${TABLES[@]}"; do
        if [ "$(fact "pre_sha:$t")" = "$(fact "rec_sha:$t")" ]; then same=same; else same=replaced; fi
        printf '  %-32s %8s %-15s -> %8s %-15s %s\n' "$t" "$(fact "pre_hrows:$t")" "$(short "$(fact "pre_sha:$t")")" \
            "$(fact "rec_rows:$t")" "$(short "$(fact "rec_sha:$t")")" "$same"
    done
    echo "  refresh time                     $(fact pre_stamp) -> $(fact rec_stamp)"
    echo "sequences     : last value now vs the archive's highest id"
    for t in "${TABLES[@]}"; do
        if [ "$(fact "predict:$t")" = BEHIND ]; then same="BEHIND - a live restore would end 54"; else same=OK; fi
        printf '  %-32s %10s vs %-10s %s\n' "$t" "$(fact "pre_seq:$t")" "$(fact "ext_maxid:$t")" "$same"
    done
    if [ -n "$(fact prebackup_rc)" ]; then
        echo "pre-restore   : 09a exit $(fact prebackup_rc)  $(fact prebackup_folder)"
        echo "                archive $(fact prebackup_archive)  record $(fact prebackup_record)"
    fi
    if [ ${#CMD[@]} -gt 0 ]; then echo "command       : $(show_cmd)"; fi
    echo "transaction   : executed=$TRANSACTION_EXECUTED python_exit=${PY_RC:-not run}"
    if [ "$TRANSACTION_EXECUTED" = yes ]; then
        if [ -f "$DRIVER_OUT" ]; then
            while IFS= read -r line; do
                case "$line" in FD5\|*) echo "    ${line#FD5|}" ;; esac
            done < "$DRIVER_OUT"
        fi
        if [ -n "$(fact post_stamp_ok)" ]; then
            echo "fresh check   : refresh_time=$(fact post_stamp) postmaster_start=$(fact post_postmaster_start) 06c=$(fact post_06c_pass)/$(fact post_06c_rows)"
            for t in "${TABLES[@]}"; do
                printf '  %-32s %8s %-15s seq %s / max(id) %s\n' "$t" "$(fact "post_hrows:$t")" \
                    "$(short "$(fact "post_sha:$t")")" "$(fact "post_seq:$t")" "$(fact "post_maxid:$t")"
            done
        fi
        echo "vacuum        : executed=$VACUUM_EXECUTED exit=${VACUUM_RC:-not run}"
        if [ -z "$FACTS_FILE" ]; then echo "logs          : $RUN_DIR  (root-only: read with sudo)"; fi
    fi
    case "$CODE" in
        0)  if [ "$DRY_RUN" = 1 ]; then word="PRE-CHECKS PASSED - dry run, nothing was started"
            elif test_mode; then word="ROLLBACK-ONLY TEST PASSED - nothing was committed"
            else word="RESTORED AND VERIFIED"; fi ;;
        50) word="REFUSED - nothing was written" ;;
        51) word="TECHNICAL FAILURE - rolled back" ;;
        52) word="CHECKS FAILED - rolled back" ;;
        53) word="OUTCOME NOT CONFIRMED - NO GUARANTEE" ;;
        54) word="RESTORED AND VERIFIED - FOLLOW-UP NEEDED" ;;
        *)  word="UNEXPECTED" ;;
    esac
    echo "------------------------------------------------------------"
    echo "result        : $word"
    for line in "${REASONS[@]}"; do echo "  - $line"; done
    echo "TRANSACTION_EXECUTED=$TRANSACTION_EXECUTED"
    echo "TRANSACTION_COMMITTED=$COMMITTED"
    echo "VACUUM_EXECUTED=$VACUUM_EXECUTED"
    if [ "$(fact prebackup_ok)" = yes ]; then echo "PRE_RESTORE_BACKUP=$(fact prebackup_folder)"
    else echo "PRE_RESTORE_BACKUP=none"; fi
    if [ "$DRY_RUN" = 0 ] && ! test_mode && [ "$COMMITTED" = yes ] \
            && { [ "$CODE" = 0 ] || [ "$CODE" = 54 ]; }; then
        echo "RECORD_FINGERPRINT_JSON=$(fact rec_fp)"
    fi
    echo "RESULT=$CODE"
}

refuse() {
    CODE=50 REASONS=("${REFUSE[@]}")
    report
    exit 50
}

# ---- main --------------------------------------------------------------------
WORK="$TMP_ROOT/fd_section5_work_$STAMP"
mkdir -m 0700 "$WORK" || die "could not create the work folder $WORK"
CREATED+=("$WORK")
if [ -z "$FACTS_FILE" ]; then
    env_facts
    file_facts
    folder_facts
fi
record_facts
register_facts
archive_facts
if [ -n "$FACTS_FILE" ] && [ "$(fact test_extract_real)" != yes ]; then
    :                                            # (test) the facts hold the archive's contents
elif [ "$(fact rec_parse)" = ok ] && [ -n "$(fact archive_sha)" ] \
        && [ "$(fact archive_sha)" = "$(fact rec_archive_sha)" ]; then
    extract_facts                                # read only the archive the record describes
else
    F[scope_ok]=false
    F[scope_detail]="not read: the archive is not the one the record describes"
fi
if [ -z "$FACTS_FILE" ]; then
    ASSESS_OK=yes
    for key in "${ASSESS_KEYS[@]}"; do pin_ok "$key" || ASSESS_OK=no; done
    if [ "$ASSESS_OK" = yes ]; then
        assess pre
        case "$(fact pre_assess_code)" in
            0|10) read_layer pre; live_column_facts ;;
            *) ;;                                 # never query a database the assessment did not confirm
        esac
    else
        F[pre_assess_code]=not-run
    fi
else
    assess pre                                   # (test) normalises the facts' fingerprint
fi
predict
decide_pre
if [ ${#REFUSE[@]} -gt 0 ]; then refuse; fi
build_cmd
if [ "$DRY_RUN" = 1 ]; then
    CODE=0 REASONS=("every pre-check passed and the current layer was read; the command above was NOT run")
    report
    exit 0
fi

if [ -z "$FACTS_FILE" ]; then
    RUN_DIR="/tmp/fd_section5_restore_$STAMP"
    mkdir -m 0700 "$RUN_DIR" || die "could not create $RUN_DIR - nothing was started"
    DRIVER_OUT="$RUN_DIR/driver.out"
    DRIVER_ERR="$RUN_DIR/driver.err"
fi
if [ "$LIVE" = 1 ]; then
    prebackup
    decide_prebackup
    if [ ${#REFUSE[@]} -gt 0 ]; then refuse; fi
    assess final
    decide_final
    if [ ${#REFUSE[@]} -gt 0 ]; then refuse; fi
fi
if [ -z "$FACTS_FILE" ] || [ -n "$(fact test_data_root)" ]; then
    if [ -n "$FACTS_FILE" ]; then TMP_ROOT=$(fact test_data_root); fi
    prepare_data
fi
build_cmd

if run_transaction; then PY_RC=0; else PY_RC=$?; fi
parse_driver "$DRIVER_OUT"
if [ -n "$FACTS_FILE" ] && [ "$(fact test_die_after_transaction)" = yes ]; then
    die "(test) an error after the transaction started"     # proves die() never says 2 here
fi
read_layer post
decide_post
if [ "$NEED_VACUUM" = yes ]; then
    VACUUM_EXECUTED=yes
    if do_vacuum; then VACUUM_RC=0; else VACUUM_RC=$?; fi
    if [ "$VACUUM_RC" != 0 ]; then
        CODE=54
        REASONS+=("VACUUM (ANALYZE) failed (exit $VACUUM_RC). The restored data is verified and stays; run VACUUM (ANALYZE) on the five tables by hand")
    fi
fi
if [ "$FRESH" = yes ]; then fresh_state; fi

if [ -z "$FACTS_FILE" ] && [ -d "$RUN_DIR" ] && report > "$RUN_DIR/result.txt" 2>&1; then
    cat "$RUN_DIR/result.txt"
else
    report
fi
exit "$CODE"
