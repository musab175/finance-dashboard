#!/usr/bin/env bash
# =============================================================================
# 09a_backup_with_record.sh - Finance Dashboard bootstrap, SECTION 5 (shared
# with Section 6): a VERIFIED backup of the reporting layer, with a RECORD of
# the ledger state it belongs to. 2026-10-14.
#
# ONE IMPLEMENTATION, TWO CALLERS. Section 5 owns this file, its tests and its
# pin. Section 6 calls this same pinned file, never a copy: after a successful
# build (expected 0) and before a refresh of an existing layer (expected 57).
# Retention is Section 6's: this script never deletes a backup.
#
# READ-ONLY FOR THE DATABASE. It writes only inside the backup store.
#   1. Pre-checks    every file it runs matches its pinned SHA-256, checked
#                    before anything runs; Odoo stopped, no Odoo process (only
#                    then are the ledger statistics in the fingerprint complete,
#                    see 10_assess.sh LIMITS); the store and every folder above
#                    it are root's and closed to everyone else, and postgres can
#                    pass through the store but not list it
#   2. Assessment 1  10_assess.sh --state-file STATE: exit code, verdict,
#                    fingerprint. Only 0 NOTHING TO DO and 10 REFRESH go on:
#                    only they prove the target and a complete ORM-built layer
#   3. Backup        12d_verify_backup.sh --out-root STORE, pinned, unchanged:
#                    07 (unchanged) dumps the five tables as postgres; E1
#                    completed, E2 exactly the five tables, E3 each readable,
#                    E4 each table's rows equal the live table byte for byte
#                    (row count and SHA-256 of the sorted COPY lines)
#   4. Seal          root takes the folder over (0700, files 0400) and hashes
#                    the archive again: it must equal 12d's E1 hash, so nothing
#                    changed it while postgres owned it. The refresh time is
#                    read from the archive's own coverage rows and must equal
#                    the live one (read exactly as Section 4 reads it)
#   5. Assessment 2  the same exit code and fingerprint, and the state file
#                    unchanged - otherwise something moved during the backup
#   6. Record        record.json written atomically (0400), the folder renamed
#                    fd_backup_<UTC>, one line appended to register.tsv (0600)
#
# RESTORABLE means: both assessments said NOTHING TO DO with the identical
# fingerprint, AND the state file is TRUSTED - a regular file owned by root, not
# group- or world-writable, every folder above it root's and not group- or
# world-writable, no symbolic link on the way. A last-success record another
# account could have written proves nothing about which build the layer is.
#
# EXIT CODES
#   0   verified, RESTORABLE
#   57  verified, EVIDENCE ONLY: the assessment said REFRESH, or NOTHING TO DO
#       with an untrusted state file. A restore refuses it, in every mode
#   55  refused: nothing was created
#   56  created but NOT usable: 12d failed, the seal failed, or something moved
#       during the backup. The folder is renamed FAILED_fd_backup_<UTC> and has
#       no record and no register line, so a restore can never select it. It
#       is kept for inspection
#   2   could not run (arguments, environment): nothing was created
# Any other exit code is an unexpected abort: treat it as 56 until the store has
# been looked at. A folder still named fd_section4_backup_<UTC> can never be
# selected either: a restore takes only fd_backup_<UTC> folders that have a
# register line.
#
# MARKERS, the last lines of every run:
#   BACKUP_FOLDER=<path>          for 0, 57 and 56
#   BACKUP_ARCHIVE_SHA256=<hash>  for 0 and 57
#   BACKUP_RECORD_SHA256=<hash>   for 0 and 57
#   BACKUP_RESTORABLE=yes|no
#   BACKUP_RESULT=<exit code>
# Copy the two SHA-256 values OFF the server (the vault). A live restore is
# confirmed with them, and the off-server copy is the only one root on this
# server cannot change.
#
# USAGE
#   sudo bash 09a_backup_with_record.sh [--state-file /absolute/path]
#        default state file: /var/lib/fd-bootstrap/state.json (10_assess.sh's)
#   bash 09a_backup_with_record.sh --list-pins
#   bash 09a_backup_with_record.sh --facts FILE      (test) made-up facts, 12d
#        output from a file, a scratch store named in the facts; never as root
#
# The same folder must hold, all pinned: 12d_verify_backup.sh,
# 07_backup_reporting.sh, 10_assess.sh, 10a_assess_target.sql,
# 10b_assess_facts.sql, 06c_validate_cross_table.sql.
# =============================================================================
set -euo pipefail

ODOO_BIN=/mnt/data/app/bin/odoo
ODOO_SERVICE=odoo
DATABASE=gftuae
SOCKET_DIR=/var/run/postgresql
SOCKET_PORT=5432
STORE=/var/backups/finance-dashboard
STATE_FILE=/var/lib/fd-bootstrap/state.json
RECORD_VERSION=1
TABLES=(finance_dashboard_daily finance_dashboard_arap_daily
        finance_dashboard_aging_daily finance_dashboard_expense_daily
        finance_dashboard_coverage)
# The SAME text 12_refresh.sh and 12a_refresh_transaction.py use.
STAMP_SQL="SELECT COALESCE(to_char(max(last_refresh_at), 'YYYY-MM-DD HH24:MI:SS.US'), '') FROM finance_dashboard_coverage"

PIN_KEYS=(12d_verify_backup.sh 07_backup_reporting.sh 10_assess.sh
          10a_assess_target.sql 10b_assess_facts.sql 06c_validate_cross_table.sql)
declare -A PIN=(
    [12d_verify_backup.sh]=ba405fdcbd7303bf0c8de4993a2aab3dc14ed263c92e1b7f389054433987d980
    [07_backup_reporting.sh]=e72c757a1bd13672f98115c89670621fef0f735f4856959500fd1d909a5935c8
    [10_assess.sh]=067b7e4f11de389cb49caea4d902a547b6204c18c91f4d0e5d0306b4548870e5
    [10a_assess_target.sql]=b6b9da8d51099f03c4ca82b5f109b73bf0a0430202f15671f50ac6e554bc340a
    [10b_assess_facts.sql]=37809ddc91cc74a5bf7619dea032761b4e6ba64996444fd77d1f598db7637dab
    [06c_validate_cross_table.sql]=4c008824249f86bd2c1065c22eb32bea0687a2542d527ba2c21bdd71e6905708
)

# 12d's lines, matched exactly (12d is pinned, so its wording cannot change).
RE_D12_DIR='/fd_section4_backup_([0-9]{8}T[0-9]{6}Z)$'
RE_E1='^PASS  E1 completed: 07 exited 0; (fd_reporting_gftuae_[0-9]{8}T[0-9]{6}Z\.dump), ([0-9]+) bytes, sha256 ([0-9a-f]{64})$'
RE_E2='^PASS  E2 scope: '
RE_E3='^PASS  E3 readable: ([a-z_]+) - columns (\(.+\))$'
RE_E4='^PASS  E4 exact: ([a-z_]+) - ([0-9]+) rows, archive = live, sha256 ([0-9a-f]{64})$'
RE_STAMP='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
FACTS_FILE=

CODE=
REASONS=()
REFUSE=()
TRUSTED=no
UNTRUSTED_WHY=
D12_RC=
D12_OUT=
D12_DIR=
D12_STAMP=
D12_BAD=()
FINAL_DIR=
ARCHIVE_FILE= ARCHIVE_BYTES= ARCHIVE_SHA= SEALED_SHA= ARCHIVE_STAMP=
RECORD_SHA=
RESTORABLE=no
STEP=pre-checks
declare -A F=() T_ROWS=() T_SHA=() T_COLS=() N_E3=() N_E4=()
fact() { printf '%s' "${F[$1]:-}"; }

load() {    # key|value lines on stdin -> F. A later line overrides an earlier one.
    local k v
    while IFS='|' read -r k v; do
        if [ -n "$k" ]; then F["$k"]=$v; fi
    done
}

markers() {
    if [ -n "$FINAL_DIR" ]; then echo "BACKUP_FOLDER=$FINAL_DIR"; fi
    if [ "$CODE" = 0 ] || [ "$CODE" = 57 ]; then
        echo "BACKUP_ARCHIVE_SHA256=$SEALED_SHA"
        echo "BACKUP_RECORD_SHA256=$RECORD_SHA"
    fi
    echo "BACKUP_RESTORABLE=$RESTORABLE"
    echo "BACKUP_RESULT=$CODE"
}

usage() {   # could not run: nothing was created
    echo "09a_backup_with_record.sh: $*" >&2
    echo "BACKUP_RESTORABLE=no"
    echo "BACKUP_RESULT=2"
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --state-file) STATE_FILE=${2:-}; [ -n "$STATE_FILE" ] || usage "--state-file needs a path"; shift 2 ;;
        --facts)      FACTS_FILE=${2:-}; [ -n "$FACTS_FILE" ] || usage "--facts needs a file"; shift 2 ;;
        --list-pins)
            for key in "${PIN_KEYS[@]}"; do printf '%s|%s\n' "$key" "${PIN[$key]}"; done
            exit 0 ;;
        *) usage "unknown argument: $1" ;;
    esac
done
case "$STATE_FILE" in
    /*) ;;
    *) usage "--state-file must be an absolute path, not '$STATE_FILE'" ;;
esac
if [ -n "$FACTS_FILE" ]; then
    [ "$(id -u)" != 0 ] || usage "--facts is a test mode and never runs as root"
    [ -r "$FACTS_FILE" ] || usage "cannot read the facts file $FACTS_FILE"
    load < "$FACTS_FILE"
    STORE=$(fact test_store)
    case "$STORE" in
        /*) ;;
        *) usage "the facts name no absolute test_store" ;;
    esac
    [ "$STORE" != /var/backups/finance-dashboard ] || usage "a test never writes into the real backup store"
    [ -d "$STORE" ] || usage "test_store $STORE is not a directory"
else
    [ "$(id -u)" = 0 ] || usage "run with sudo: the backup store is root's"
fi
# Children (psql as postgres, python3) never inherit a folder another account
# can write, or one they cannot enter.
cd /

q_sql() {   # one read-only statement through the local socket -> its value
    sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on' \
        psql -X -At -v ON_ERROR_STOP=1 \
             -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" -c "$1"
}

hash_of() { sha256sum "$1" | awk '{print $1}'; }

pin_ok() { [ "$(fact "file_sha:$1")" = "${PIN[$1]}" ]; }

chain() {   # absolute path -> "path:uid:mode:kind;..." for / and each component
    local path=$1 cur= out item comp kind
    local -a parts
    item=$(stat -c '%u:%a:%F' /)
    out="/:${item%%:*}:$(cut -d: -f2 <<<"$item"):d"
    IFS=/ read -r -a parts <<<"${path#/}"
    for comp in "${parts[@]}"; do
        if [ -z "$comp" ]; then continue; fi
        cur="$cur/$comp"
        if [ ! -e "$cur" ] && [ ! -L "$cur" ]; then
            out="$out;$cur:-:-:missing"
            break
        fi
        item=$(stat -c '%u:%a:%F' "$cur")       # lstat: a link is reported as a link
        case "${item#*:*:}" in
            directory)                         kind=d ;;
            "regular file"|"regular empty file") kind=f ;;
            "symbolic link")                   kind=l ;;
            *)                                 kind=o ;;
        esac
        out="$out;$cur:$(cut -d: -f1,2 <<<"$item"):$kind"
    done
    printf '%s' "$out"
}

collect_pre() {     # real mode: everything the pre-checks decide on
    local key path
    F[hostname]=$(hostname)
    for key in "${PIN_KEYS[@]}"; do
        path="$HERE/$key"
        if [ -f "$path" ]; then F["file_sha:$key"]=$(hash_of "$path"); else F["file_sha:$key"]=missing; fi
    done
    F[self_sha]=$(hash_of "$SELF")
    F[odoo_service]=$(systemctl is-active "$ODOO_SERVICE" 2>/dev/null || true)
    F[odoo_processes]=$(pgrep -fc -- "$ODOO_BIN" || true)
    F[store_chain]=$(chain "$STORE")
    if sudo -u postgres test -x "$STORE"; then F[store_pg_traverse]=true; else F[store_pg_traverse]=false; fi
    if sudo -u postgres test -r "$STORE"; then F[store_pg_list]=true; else F[store_pg_list]=false; fi
    if [ -e "$STORE/register.tsv" ] || [ -L "$STORE/register.tsv" ]; then
        F[register_chain]=$(chain "$STORE/register.tsv")
    else
        F[register_chain]=absent
    fi
    F[state_chain]=$(chain "$STATE_FILE")
    F[state_sha_before]=$(state_sha)
}

state_sha() {
    if [ -f "$STATE_FILE" ]; then hash_of "$STATE_FILE"; else echo missing; fi
}

state_fp() {        # the state file's last_success fingerprint, as 10_assess.sh reads it
    python3 - "$STATE_FILE" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        doc = json.load(fh)
    fp = doc["last_success"]["fingerprint"]
    if isinstance(fp, dict):
        print(json.dumps(fp, sort_keys=True))
except Exception:
    pass
PY
}

assess() {          # $1 = 1|2 : a fresh Section 2 assessment against the state file
    local out code=0
    out=$(bash "$HERE/10_assess.sh" --state-file "$STATE_FILE" 2>&1) || code=$?
    F["a$1_code"]=$code
    F["a$1_verdict"]=$(awk -F= '/^VERDICT=/ {v = $2} END {print v}' <<<"$out")
    F["a$1_fp"]=$(awk '/^FINGERPRINT_JSON=/ {sub(/^FINGERPRINT_JSON=/, ""); v = $0} END {print v}' <<<"$out")
    F["a$1_reasons"]=$(awk '/^verdict     :/ {f = 1; next}
                           f && /^  - / {sub(/^  - /, ""); printf "%s%s", sep, $0; sep = " ;; "}
                           /^FINGERPRINT_JSON=|^VERDICT=/ {f = 0}' <<<"$out")
}

fp_valid() {        # $1 = fingerprint JSON -> true when all six parts are non-empty strings
    python3 - "$1" <<'PY'
import json, sys
keys = ("uuid", "postmaster_start", "max_aml_id",
        "aml_n_tup_ins", "aml_n_tup_upd", "aml_n_tup_del")
try:
    fp = json.loads(sys.argv[1])
except ValueError:
    fp = None
ok = isinstance(fp, dict) and all(isinstance(fp.get(k), str) and fp.get(k) for k in keys)
print("true" if ok else "false")
PY
}

chain_problems() { # $1 = chain, $2 = kind the last part must be (d|f) -> one line per problem
    local item path uid mode kind n=0 total want
    local -a items
    IFS=';' read -r -a items <<<"$1"
    total=${#items[@]}
    if [ "$2" = d ]; then want=directory; else want="regular file"; fi
    for item in "${items[@]}"; do
        n=$((n + 1))
        IFS=: read -r path uid mode kind <<<"$item"
        if [ "$kind" = missing ]; then echo "$path does not exist"; return 0; fi
        if [ "$kind" = l ]; then echo "$path is a symbolic link"; continue; fi
        if [ "$uid" != 0 ]; then echo "$path is owned by uid $uid, not root"; fi
        if [ "$n" -lt "$total" ] && [ "$kind" != d ]; then echo "$path is not a directory"; fi
        if [ "$n" = "$total" ] && [ "$kind" != "$2" ]; then echo "$path is not a $want"; fi
        if ! [[ $mode =~ ^[0-7]{3,4}$ ]]; then echo "$path has an unreadable mode '$mode'"
        elif (( (8#$mode & 8#022) != 0 )); then echo "$path is writable by its group or by others (mode $mode)"; fi
    done
}

last_mode() { local last=${1##*;}; cut -d: -f3 <<<"$last"; }

decide_pre() {      # facts -> REFUSE[], TRUSTED. Reads nothing else.
    local key sha line mode code
    for key in "${PIN_KEYS[@]}"; do
        sha=$(fact "file_sha:$key")
        if [ "$sha" = missing ] || [ -z "$sha" ]; then
            REFUSE+=("$key is missing")
        elif ! pin_ok "$key"; then
            REFUSE+=("$key does not match its approved hash (found ${sha:0:12}...)")
        fi
    done
    case "$(fact odoo_service)" in
        inactive|failed) ;;
        *) REFUSE+=("Odoo service is '$(fact odoo_service)' - stop it first: the fingerprint's ledger statistics are complete only with Odoo stopped; this script never stops or starts Odoo") ;;
    esac
    [ "$(fact odoo_processes)" = 0 ] \
        || REFUSE+=("$(fact odoo_processes) Odoo process(es) still running from $ODOO_BIN")
    while IFS= read -r line; do
        if [ -n "$line" ]; then REFUSE+=("backup store: $line"); fi
    done <<<"$(chain_problems "$(fact store_chain)" d)"
    mode=$(last_mode "$(fact store_chain)")
    if [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#067) != 0 )); then
        REFUSE+=("backup store: $STORE is open to its group or to others (mode $mode) - only root, and postgres passing through, may use it")
    fi
    [ "$(fact store_pg_traverse)" = true ] \
        || REFUSE+=("backup store: postgres cannot pass through $STORE - 07 writes the archive as postgres")
    [ "$(fact store_pg_list)" = false ] \
        || REFUSE+=("backup store: postgres can list $STORE - it must not see the other backups")
    if [ "$(fact register_chain)" != absent ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then REFUSE+=("register: $line"); fi
        done <<<"$(chain_problems "$(fact register_chain)" f)"
        mode=$(last_mode "$(fact register_chain)")
        [ "$mode" = 600 ] || REFUSE+=("register: $STORE/register.tsv has mode $mode, expected 600")
    fi
    UNTRUSTED_WHY=$(chain_problems "$(fact state_chain)" f | paste -sd';' - | sed 's/;/; /g')
    if [ -z "$UNTRUSTED_WHY" ]; then TRUSTED=yes; else TRUSTED=no; fi
}

decide_assessment() {   # assessment 1 -> REFUSE[]
    local code=$(fact a1_code) verdict=$(fact a1_verdict)
    case "$code" in
        0)  [ "$verdict" = "NOTHING TO DO" ] || REFUSE+=("inconsistent: the assessment exited 0 with verdict '$verdict'") ;;
        10) [ "$verdict" = REFRESH ] || REFUSE+=("inconsistent: the assessment exited 10 with verdict '$verdict'") ;;
        11) REFUSE+=("the assessment says INSTALL + REFRESH - there is no layer to back up") ;;
        20) REFUSE+=("the assessment says STOP: wrong target - not the expected reporting environment") ;;
        21) REFUSE+=("the assessment says STOP: pending modules - investigate manually") ;;
        22) REFUSE+=("the assessment says STOP: layer anomaly - investigate; a backup of it is not taken") ;;
        2)  REFUSE+=("the Section 2 assessment did not complete - the environment cannot be confirmed") ;;
        *)  REFUSE+=("the Section 2 assessment returned unexpected exit code '$code'") ;;
    esac
    if { [ "$code" = 0 ] || [ "$code" = 10 ]; } && [ "$(fp_valid "$(fact a1_fp)")" != true ]; then
        REFUSE+=("the assessment printed no complete fingerprint - the backup could not be recorded")
    fi
}

run_12d() {
    if [ -n "$FACTS_FILE" ]; then
        D12_RC=$(fact test_d12_rc)
        D12_OUT=$(cat "$(fact test_d12_output)")
        return 0
    fi
    D12_RC=0
    D12_OUT=$(bash "$HERE/12d_verify_backup.sh" --out-root "$STORE" 2>&1) || D12_RC=$?
}

parse_12d() {       # D12_OUT -> D12_DIR, ARCHIVE_*, T_*; problems -> D12_BAD[]
    local line last= n_e1=0 n_e2=0 n_e3=0 n_e4=0 t
    while IFS= read -r line; do
        if [ -n "$line" ]; then last=$line; fi
        case "$line" in
            "folder      : "*) D12_DIR=${line#folder      : } ;;
            "FAIL  "*)         D12_BAD+=("12d reported: ${line#FAIL  }") ;;
        esac
        if [[ $line =~ $RE_E1 ]]; then
            n_e1=$((n_e1 + 1))
            ARCHIVE_FILE=${BASH_REMATCH[1]} ARCHIVE_BYTES=${BASH_REMATCH[2]} ARCHIVE_SHA=${BASH_REMATCH[3]}
        elif [[ $line =~ $RE_E2 ]]; then
            n_e2=$((n_e2 + 1))
        elif [[ $line =~ $RE_E3 ]]; then
            n_e3=$((n_e3 + 1)); t=${BASH_REMATCH[1]}
            N_E3[$t]=$(( ${N_E3[$t]:-0} + 1 )); T_COLS[$t]=${BASH_REMATCH[2]}
        elif [[ $line =~ $RE_E4 ]]; then
            n_e4=$((n_e4 + 1)); t=${BASH_REMATCH[1]}
            N_E4[$t]=$(( ${N_E4[$t]:-0} + 1 )); T_ROWS[$t]=${BASH_REMATCH[2]} T_SHA[$t]=${BASH_REMATCH[3]}
        fi
    done <<<"$D12_OUT"
    [ "$D12_RC" = 0 ] || D12_BAD+=("12d exited $D12_RC")
    [ "$last" = BACKUP_EVIDENCE=PASS ] || D12_BAD+=("12d's last line is '$last', not BACKUP_EVIDENCE=PASS")
    [ "$n_e1" = 1 ] || D12_BAD+=("12d printed $n_e1 E1 PASS line(s), expected 1")
    [ "$n_e2" = 1 ] || D12_BAD+=("12d printed $n_e2 E2 PASS line(s), expected 1")
    [ "$n_e3" = 5 ] || D12_BAD+=("12d printed $n_e3 E3 PASS line(s), expected 5")
    [ "$n_e4" = 5 ] || D12_BAD+=("12d printed $n_e4 E4 PASS line(s), expected 5")
    for t in "${TABLES[@]}"; do
        [ "${N_E3[$t]:-0}" = 1 ] && [ "${N_E4[$t]:-0}" = 1 ] \
            || D12_BAD+=("$t: ${N_E3[$t]:-0} E3 and ${N_E4[$t]:-0} E4 PASS line(s), expected one each")
    done
    if [ -n "$D12_DIR" ]; then
        if [[ $D12_DIR =~ $RE_D12_DIR ]] && [ "$D12_DIR" = "$STORE/fd_section4_backup_${BASH_REMATCH[1]}" ]; then
            D12_STAMP=${BASH_REMATCH[1]}
        else
            D12_BAD+=("12d reported the folder '$D12_DIR', not one directly in $STORE")
        fi
    fi
}

ours() {            # true when 12d created a folder this script may seal or rename
    [ -n "$D12_STAMP" ] && [ -d "$D12_DIR" ] && [ ! -L "$D12_DIR" ]
}

lock_down() {       # root takes the folder over: 0700, every file 0400
    if [ -z "$FACTS_FILE" ]; then chown -R root:root "$D12_DIR"; fi
    chmod 0700 "$D12_DIR"
    find "$D12_DIR" -mindepth 1 -maxdepth 1 -type f -exec chmod 0400 {} +
}

keep_12d_output() { # 12d's own report, beside the archive
    ( umask 0377; printf '%s\n' "$D12_OUT" > "$1/12d_output.txt" )
}

unusable() {        # created but not usable -> 56: FAILED_..., no record, no register line
    CODE=56 RESTORABLE=no RECORD_SHA=
    REASONS=("$@")
    if ours; then
        lock_down 2>/dev/null || REASONS+=("could not lock $D12_DIR down completely")
        rm -f "$D12_DIR/record.json" "$D12_DIR/record.json.tmp"
        keep_12d_output "$D12_DIR" 2>/dev/null || true
        local dest="$STORE/FAILED_fd_backup_$D12_STAMP"
        if [ ! -e "$dest" ] && [ ! -L "$dest" ] && mv "$D12_DIR" "$dest"; then
            FINAL_DIR=$dest
        else
            FINAL_DIR=$D12_DIR
            REASONS+=("it could not be renamed and keeps the name $D12_DIR - still never selectable: no record, no register line")
        fi
    elif [ -n "$D12_DIR" ]; then
        FINAL_DIR=$D12_DIR
        REASONS+=("12d reported the folder $D12_DIR, which this script does not touch")
    fi
    report
    exit 56
}

seal() {            # -> SEALED_SHA, or problems
    local got want bytes
    if ! lock_down; then echo "could not give $D12_DIR to root with modes 0700/0400"; return 0; fi
    got=$(cd "$D12_DIR" && ls -A | LC_ALL=C sort | paste -sd' ' -)
    want=$(printf '%s\n' "$ARCHIVE_FILE" 07_output.txt archive_listing.txt | LC_ALL=C sort | paste -sd' ' -)
    [ "$got" = "$want" ] || echo "the folder holds [$got], expected exactly [$want]"
    if [ ! -f "$D12_DIR/$ARCHIVE_FILE" ]; then echo "the archive $ARCHIVE_FILE is missing"; return 0; fi
    SEALED_SHA=$(hash_of "$D12_DIR/$ARCHIVE_FILE")
    [ "$SEALED_SHA" = "$ARCHIVE_SHA" ] \
        || echo "the archive's SHA-256 after sealing is $SEALED_SHA, 12d's E1 reported $ARCHIVE_SHA - it changed while postgres owned it"
    bytes=$(wc -c < "$D12_DIR/$ARCHIVE_FILE" | tr -d ' ')
    [ "$bytes" = "$ARCHIVE_BYTES" ] || echo "the archive is $bytes bytes, 12d's E1 reported $ARCHIVE_BYTES"
}

archive_stamp() {   # the refresh time from the ARCHIVE's coverage rows, formatted like STAMP_SQL
    local file=$1 cols idx
    if [ -n "$FACTS_FILE" ] && [[ -v F[test_archive_stamp] ]]; then   # (test) given, even empty
        fact test_archive_stamp; return 0
    fi
    cols=${T_COLS[finance_dashboard_coverage]:-}
    idx=$(tr -d '()' <<<"$cols" | awk -F', ' '{for (i = 1; i <= NF; i++) if ($i == "last_refresh_at") print i}')
    [ -n "$idx" ] || return 1
    pg_restore --data-only -t finance_dashboard_coverage -f - "$file" \
        | awk -F'\t' -v i="$idx" '
            f && /^\\\.$/ {f = 0; next}
            f && $i != "\\N" {
                v = $i
                if (index(v, ".") == 0) v = v ".000000"
                else { split(v, p, "."); v = p[1] "." substr(p[2] "000000", 1, 6) }
                if (v > m) m = v
            }
            /^COPY / {f = 1}
            END {print m}'
}

decide_post() {     # after the backup -> CODE, RESTORABLE; MOVED[] when something changed
    MOVED=()
    [ "$(fact a2_code)" = "$(fact a1_code)" ] \
        || MOVED+=("the assessment's exit code changed during the backup: $(fact a1_code) -> $(fact a2_code) ($(fact a2_verdict))")
    [ "$(fact a2_fp)" = "$(fact a1_fp)" ] \
        || MOVED+=("the fingerprint changed during the backup: $(fact a1_fp) -> $(fact a2_fp)")
    [ "$(fact state_sha_after)" = "$(fact state_sha_before)" ] \
        || MOVED+=("the state file changed during the backup ($(fact state_sha_before) -> $(fact state_sha_after))")
    [ "$(fact live_stamp)" = "$ARCHIVE_STAMP" ] \
        || MOVED+=("the live refresh time is '$(fact live_stamp)', the archive's is '$ARCHIVE_STAMP' - the layer changed during the backup")
    if [ "$(fact a1_code)" = 0 ] && ! [[ $ARCHIVE_STAMP =~ $RE_STAMP ]]; then
        MOVED+=("NOTHING TO DO, yet the archive holds no valid refresh time ('$ARCHIVE_STAMP')")
    fi
    if [ ${#MOVED[@]} -gt 0 ]; then return 0; fi
    if [ "$(fact a1_code)" = 0 ] && [ "$TRUSTED" = yes ]; then
        CODE=0 RESTORABLE=yes
        REASONS=("both assessments said NOTHING TO DO with the identical fingerprint; the state file is trusted and did not change; the archive equals the live layer (E4) and holds its refresh time")
    else
        CODE=57 RESTORABLE=no
        if [ "$(fact a1_code)" = 10 ]; then
            REASONS=("EVIDENCE ONLY: the assessment said REFRESH, so this layer is not proven to be the last successful build ($(fact a1_reasons))")
        else
            REASONS=("EVIDENCE ONLY: the assessment said NOTHING TO DO, but the state file is not trusted: $UNTRUSTED_WHY")
        fi
    fi
}

write_record() {    # record.json, atomically, 0400 -> RECORD_SHA (or a problem line)
    local args=() t key py_sha
    args=("test=$( [ -n "$FACTS_FILE" ] && echo true || echo false )"
          "backup_stamp=$D12_STAMP" "host=$(fact hostname)" "database=$DATABASE"
          "restorable=$( [ "$RESTORABLE" = yes ] && echo true || echo false )"
          "state_path=$STATE_FILE" "state_sha256=$(fact state_sha_before)"
          "state_trusted=$( [ "$TRUSTED" = yes ] && echo true || echo false )"
          "state_untrusted_why=$UNTRUSTED_WHY" "state_fp=$(fact state_fp)"
          "a1_code=$(fact a1_code)" "a1_verdict=$(fact a1_verdict)" "a1_fp=$(fact a1_fp)"
          "a1_reasons=$(fact a1_reasons)"
          "a2_code=$(fact a2_code)" "a2_verdict=$(fact a2_verdict)" "a2_fp=$(fact a2_fp)"
          "a2_reasons=$(fact a2_reasons)"
          "stamp=$ARCHIVE_STAMP"
          "archive_file=$ARCHIVE_FILE" "archive_bytes=$ARCHIVE_BYTES" "archive_sha256=$SEALED_SHA"
          "tool:09a_backup_with_record.sh=$(fact self_sha)")
    for key in "${PIN_KEYS[@]}"; do args+=("tool:$key=$(fact "file_sha:$key")"); done
    for t in "${TABLES[@]}"; do args+=("table:$t=${T_ROWS[$t]}|${T_COLS[$t]}|${T_SHA[$t]}"); done
    for t in "${REASONS[@]}"; do args+=("reason=$t"); done
    if ! py_sha=$(python3 - "$D12_DIR/record.json.tmp" "$D12_DIR/record.json" "$RECORD_VERSION" "${args[@]}" <<'PY'
import datetime, hashlib, json, os, sys

tmp, final, version = sys.argv[1], sys.argv[2], int(sys.argv[3])
kv, tables, tools, reasons = {}, {}, {}, []
for arg in sys.argv[4:]:
    key, _, value = arg.partition("=")
    if key == "reason":
        reasons.append(value)
    elif key.startswith("table:"):
        rows, cols, sha = value.split("|")
        tables[key[6:]] = {"rows": int(rows), "columns": cols, "copy_sha256": sha}
    elif key.startswith("tool:"):
        tools[key[5:]] = value
    else:
        kv[key] = value

def fp(text):
    return json.loads(text) if text else None

def reason_list(text):
    return [r for r in text.split(" ;; ") if r]

record = {
    "record_version": version,
    "kind": "finance-dashboard reporting-layer backup",
    "test": kv["test"] == "true",
    "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "backup_stamp": kv["backup_stamp"],
    "host": kv["host"],
    "database": kv["database"],
    "restorable": kv["restorable"] == "true",
    "reasons": reasons,
    "fingerprint": fp(kv["a1_fp"]),
    "layer_refresh_time": kv["stamp"],
    "archive": {"file": kv["archive_file"], "bytes": int(kv["archive_bytes"]),
                "sha256": kv["archive_sha256"]},
    "tables": tables,
    "state_file": {"path": kv["state_path"], "sha256": kv["state_sha256"],
                   "trusted": kv["state_trusted"] == "true",
                   "not_trusted_because": kv["state_untrusted_why"] or None,
                   "fingerprint": fp(kv["state_fp"])},
    "assessment_before": {"exit": int(kv["a1_code"]), "verdict": kv["a1_verdict"],
                          "fingerprint": fp(kv["a1_fp"]), "reasons": reason_list(kv["a1_reasons"])},
    "assessment_after": {"exit": int(kv["a2_code"]), "verdict": kv["a2_verdict"],
                         "fingerprint": fp(kv["a2_fp"]), "reasons": reason_list(kv["a2_reasons"])},
    "tools": tools,
}
data = (json.dumps(record, indent=2) + "\n").encode("utf-8")
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
with os.fdopen(fd, "wb") as fh:
    fh.write(data)
    fh.flush()
    os.fsync(fh.fileno())
os.replace(tmp, final)
print(hashlib.sha256(data).hexdigest())
PY
    ); then
        echo "the record could not be written"
        return 0
    fi
    RECORD_SHA=$(hash_of "$D12_DIR/record.json")
    [ "$RECORD_SHA" = "$py_sha" ] || echo "record.json's SHA-256 on disk ($RECORD_SHA) differs from what was written ($py_sha)"
}

append_register() { # one line per usable backup; the register is only ever appended to
    local reg="$STORE/register.tsv"
    (
        umask 077
        if [ ! -e "$reg" ]; then
            printf '# created_utc\tfolder\tresult\trestorable\tarchive_sha256\trecord_sha256\n' >> "$reg"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$FINAL_DIR")" \
            "$CODE" "$RESTORABLE" "$SEALED_SHA" "$RECORD_SHA" >> "$reg"
    )
}

mode_text() {
    if [ -n "$FACTS_FILE" ]; then printf 'TEST (made-up facts, scratch store %s)' "$STORE"
    else printf 'LIVE - read-only for the database, writes only into %s' "$STORE"; fi
}

report() {
    local key ok=0 t word line
    for key in "${PIN_KEYS[@]}"; do if pin_ok "$key"; then ok=$((ok + 1)); fi; done
    echo "=== Finance Dashboard - verified backup with record (Section 5, shared with Section 6) ==="
    echo "mode         : $(mode_text)"
    echo "files        : $ok/${#PIN_KEYS[@]} match their approved SHA-256; this script is $(fact self_sha)"
    for key in "${PIN_KEYS[@]}"; do
        if ! pin_ok "$key"; then echo "    MISMATCH  $key  found=$(fact "file_sha:$key")"; fi
    done
    echo "odoo         : service=$(fact odoo_service) processes=$(fact odoo_processes)"
    echo "store        : $STORE  postgres pass-through=$(fact store_pg_traverse) list=$(fact store_pg_list)"
    echo "state file   : $STATE_FILE  trusted=$TRUSTED  sha256=$(fact state_sha_before)"
    if [ -n "$UNTRUSTED_WHY" ]; then echo "               not trusted: $UNTRUSTED_WHY"; fi
    if [ -n "$(fact a1_code)" ]; then echo "assessment 1 : exit $(fact a1_code) - $(fact a1_verdict)"; fi
    if [ -n "$D12_RC" ]; then
        echo "backup (12d) : exit $D12_RC  folder ${D12_DIR:-none}"
        if [ -n "$ARCHIVE_FILE" ]; then
            echo "archive      : $ARCHIVE_FILE  $ARCHIVE_BYTES bytes  E1 sha256 $ARCHIVE_SHA"
        fi
        for t in "${TABLES[@]}"; do
            if [ -n "${T_ROWS[$t]:-}" ]; then
                printf '  %-34s %9s rows  sha256 %s\n' "$t" "${T_ROWS[$t]}" "${T_SHA[$t]}"
            fi
        done
    fi
    if [ -n "$SEALED_SHA" ]; then echo "sealed       : root, folder 0700, files 0400; archive sha256 $SEALED_SHA"; fi
    if [ -n "$ARCHIVE_STAMP$(fact live_stamp)" ]; then
        echo "refresh time : archive '$ARCHIVE_STAMP'  live '$(fact live_stamp)'"
    fi
    if [ -n "$(fact a2_code)" ]; then echo "assessment 2 : exit $(fact a2_code) - $(fact a2_verdict)"; fi
    if [ -n "$RECORD_SHA" ]; then echo "record       : $FINAL_DIR/record.json  sha256 $RECORD_SHA"; fi
    case "$CODE" in
        0)  word="VERIFIED - RESTORABLE" ;;
        57) word="VERIFIED - EVIDENCE ONLY (never restorable)" ;;
        55) word="REFUSED - nothing was created" ;;
        56) word="CREATED BUT NOT USABLE - kept for inspection, never selectable" ;;
        *)  word="UNEXPECTED" ;;
    esac
    echo "------------------------------------------------------------"
    echo "result       : $word"
    for line in "${REASONS[@]}"; do echo "  - $line"; done
    markers
}

refuse() {          # 55: nothing was created
    CODE=55 RESTORABLE=no REASONS=("${REFUSE[@]}")
    report
    exit 55
}

# ---- main --------------------------------------------------------------------
if [ -z "$FACTS_FILE" ]; then collect_pre; fi
decide_pre
if [ ${#REFUSE[@]} -gt 0 ]; then refuse; fi

STEP=assessment
if [ -z "$FACTS_FILE" ]; then assess 1; fi
decide_assessment
if [ ${#REFUSE[@]} -gt 0 ]; then refuse; fi

STEP=backup
run_12d
parse_12d
if ! ours; then
    if [ -n "$D12_DIR" ]; then unusable "${D12_BAD[@]}"; fi
    usage "12d reported no backup folder (exit $D12_RC) - if it made one, it is named fd_section4_backup_<UTC> and can never be selected: $(printf '%s\n' "$D12_OUT" | grep -E 'ERROR|FAIL' | head -n 3 | paste -sd' ' -)"
fi
if [ ${#D12_BAD[@]} -gt 0 ]; then unusable "${D12_BAD[@]}"; fi

STEP=seal
SEAL_BAD=$(seal)
if [ -n "$SEAL_BAD" ]; then
    mapfile -t lines <<<"$SEAL_BAD"
    unusable "${lines[@]}"
fi
SEALED_SHA=$(hash_of "$D12_DIR/$ARCHIVE_FILE")   # seal ran in a subshell: hash again here
if ! ARCHIVE_STAMP=$(archive_stamp "$D12_DIR/$ARCHIVE_FILE"); then
    unusable "the refresh time could not be read from the archive's coverage rows"
fi
if [ -z "$FACTS_FILE" ]; then
    if ! F[live_stamp]=$(q_sql "$STAMP_SQL" 2>&1); then
        unusable "the live refresh time could not be read: $(fact live_stamp)"
    fi
fi

STEP=assessment-2
if [ -z "$FACTS_FILE" ]; then
    assess 2
    F[state_sha_after]=$(state_sha)
    F[state_fp]=$(state_fp)
fi
decide_post
if [ ${#MOVED[@]} -gt 0 ]; then unusable "something moved during the backup:" "${MOVED[@]}"; fi

STEP=record
if ! keep_12d_output "$D12_DIR"; then unusable "12d's output could not be kept beside the archive"; fi
RECORD_BAD=$(write_record)
if [ -n "$RECORD_BAD" ]; then
    mapfile -t lines <<<"$RECORD_BAD"
    unusable "${lines[@]}"
fi
RECORD_SHA=$(hash_of "$D12_DIR/record.json")
DEST="$STORE/fd_backup_$D12_STAMP"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then unusable "$DEST already exists - nothing is ever overwritten"; fi
mv "$D12_DIR" "$DEST" || unusable "the folder could not be renamed to $DEST"
FINAL_DIR=$DEST
D12_DIR=$DEST
D12_STAMP_KEEP=$D12_STAMP
if ! append_register; then
    D12_DIR=$DEST                                   # unusable() renames it FAILED_...
    D12_STAMP=$D12_STAMP_KEEP
    unusable "the register line could not be appended - the backup is not usable without it"
fi
report
exit "$CODE"
