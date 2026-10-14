#!/usr/bin/env bash
# =============================================================================
# 12d_verify_backup.sh - Finance Dashboard bootstrap, SECTION 4 TEST AID:
# evidence E1-E4 that a reporting-layer backup completed and is intact.
# 2026-10-13.
#
# READ-ONLY FOR THE DATABASE. Runs 07_backup_reporting.sh UNCHANGED (pinned)
# into a NEW folder, then proves, without restoring anything:
#   E1 completed   07 exited 0; exactly one archive, not empty; sha256 recorded
#   E2 scope       the archive defines and holds data for exactly the five
#                  reporting tables, and for no other table
#   E3 readable    every table's data extracts from the archive without error
#   E4 exact       every table's rows in the archive equal the live table's rows
#                  byte for byte - both sides as COPY text, sorted and hashed -
#                  and the row counts match
# NOT HERE, by the approved split (2026-10-13): E5, a record of which ledger
# copy the backup belongs to (Section 6), and E6, an actual restore (Section 5).
# E1-E4 show a backup completed and is intact. They do NOT show it is usable
# for recovery; only E5 and E6 can.
#
# Run it with Odoo stopped and no refresh running, between two 12c snapshots:
# identical snapshots prove the live tables did not change during the check.
#
# KNOWN LIMIT OF 07, recorded and left unchanged: its two safety checks pipe
# `pg_restore -l` into `grep -q` under pipefail. grep -q exits at its first
# match; on a listing larger than the pipe buffer pg_restore can then die of
# SIGPIPE, the pipeline returns 141, and the FAIL branch is skipped - the
# check passes exactly when it should fail. Harmless for a five-table listing,
# which pg_restore writes in full before grep reads it. E2 below does not
# depend on 07's checks: it parses the listing itself.
#
# USAGE
#   sudo bash 12d_verify_backup.sh
#   bash 12d_verify_backup.sh --socket-dir DIR --port N --database NAME
#        --os-user USER --out-root DIR      (test) a scratch cluster's socket
# Exit: 0 every check passed; 1 a check failed; 2 the script could not run.
# The last line is BACKUP_EVIDENCE=PASS or BACKUP_EVIDENCE=FAIL.
# =============================================================================
set -euo pipefail

SOCKET_DIR=/var/run/postgresql
SOCKET_PORT=5432
DATABASE=gftuae
DB_OS_USER=postgres
OUT_ROOT=/tmp
PIN_07=e72c757a1bd13672f98115c89670621fef0f735f4856959500fd1d909a5935c8
TABLES=(finance_dashboard_daily finance_dashboard_arap_daily
        finance_dashboard_aging_daily finance_dashboard_expense_daily
        finance_dashboard_coverage)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ $# -gt 0 ]; do
    case "$1" in
        --socket-dir) SOCKET_DIR=${2:?}; shift 2 ;;
        --port)       SOCKET_PORT=${2:?}; shift 2 ;;
        --database)   DATABASE=${2:?}; shift 2 ;;
        --os-user)    DB_OS_USER=${2:?}; shift 2 ;;
        --out-root)   OUT_ROOT=${2:?}; shift 2 ;;
        *) echo "unknown argument: $1" >&2; echo "BACKUP_EVIDENCE=FAIL"; exit 2 ;;
    esac
done

die() {
    echo "BACKUP CHECK ERROR: $*" >&2
    echo "BACKUP_EVIDENCE=FAIL"
    exit 2
}

# A Unix-socket directory only: no host name or address can be given, so this
# script cannot reach another server.
case "$SOCKET_DIR" in
    /*) ;;
    *) die "--socket-dir must be an absolute directory path (a local socket), not '$SOCKET_DIR'" ;;
esac
[ -d "$SOCKET_DIR" ] || die "socket directory $SOCKET_DIR does not exist"

as_db() {   # run as the database OS user; no sudo when that is already us
    if [ "$(id -un)" = "$DB_OS_USER" ]; then "$@"; else sudo -u "$DB_OS_USER" "$@"; fi
}

hash_of() { sha256sum "$1" | awk '{print $1}'; }

FAILS=()
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS+=("$1"); }

echo "=== Finance Dashboard - Section 4 test aid: backup evidence E1-E4 ==="
echo "target      : socket $SOCKET_DIR port $SOCKET_PORT database $DATABASE (as $DB_OS_USER)"

[ -f "$HERE/07_backup_reporting.sh" ] || die "07_backup_reporting.sh is not in $HERE"
SHA_07=$(hash_of "$HERE/07_backup_reporting.sh")
[ "$SHA_07" = "$PIN_07" ] \
    || die "07_backup_reporting.sh is $SHA_07, not the approved $PIN_07"
echo "backup tool : 07_backup_reporting.sh $SHA_07 (pinned, unchanged)"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$OUT_ROOT/fd_section4_backup_$STAMP"
mkdir -m 0750 "$RUN_DIR" || die "could not create $RUN_DIR"
if [ "$(id -un)" != "$DB_OS_USER" ]; then
    chown "$DB_OS_USER" "$RUN_DIR" || die "could not hand $RUN_DIR to $DB_OS_USER"
fi
echo "folder      : $RUN_DIR"

# ---- E1: 07 runs, unchanged, read-only ---------------------------------------
RC_07=0
as_db env PGHOST="$SOCKET_DIR" PGPORT="$SOCKET_PORT" PGUSER="$DB_OS_USER" \
    PGDATABASE="$DATABASE" OUTDIR="$RUN_DIR" \
    PGOPTIONS='-c default_transaction_read_only=on' \
    bash "$HERE/07_backup_reporting.sh" > "$RUN_DIR/07_output.txt" 2>&1 || RC_07=$?
shopt -s nullglob
ARCHIVES=("$RUN_DIR"/fd_reporting_*.dump)
shopt -u nullglob
if [ "$RC_07" = 0 ] && [ ${#ARCHIVES[@]} = 1 ] && [ -s "${ARCHIVES[0]}" ]; then
    ARCHIVE=${ARCHIVES[0]}
    pass "E1 completed: 07 exited 0; $(basename "$ARCHIVE"), $(wc -c < "$ARCHIVE" | tr -d ' ') bytes, sha256 $(hash_of "$ARCHIVE")"
else
    fail "E1 completed: 07 exited $RC_07 with ${#ARCHIVES[@]} archive(s) - see $RUN_DIR/07_output.txt"
    echo "------------------------------------------------------------"
    echo "BACKUP_EVIDENCE=FAIL"
    exit 1
fi

# ---- E2: exactly the five tables, nothing else -------------------------------
pg_restore -l "$ARCHIVE" > "$RUN_DIR/archive_listing.txt" \
    || { fail "E2 scope: pg_restore -l could not read the archive"; }
WANT=$(printf 'public.%s\n' "${TABLES[@]}" | LC_ALL=C sort)
GOT_TABLE=$(awk '$1 !~ /^;/ && $4 == "TABLE" && $5 != "DATA" {print $5 "." $6}' \
                "$RUN_DIR/archive_listing.txt" | LC_ALL=C sort)
GOT_DATA=$(awk '$1 !~ /^;/ && $4 == "TABLE" && $5 == "DATA" {print $6 "." $7}' \
               "$RUN_DIR/archive_listing.txt" | LC_ALL=C sort)
SEQS=$(awk '$1 !~ /^;/ && $4 == "SEQUENCE" && $5 != "SET" && $5 != "OWNED" {print $5 "." $6}' \
           "$RUN_DIR/archive_listing.txt" | LC_ALL=C sort | paste -sd' ' -)
if [ "$GOT_TABLE" = "$WANT" ] && [ "$GOT_DATA" = "$WANT" ]; then
    pass "E2 scope: definitions and data for exactly the five reporting tables; sequences: ${SEQS:-none}"
else
    fail "E2 scope: tables [$(paste -sd' ' - <<<"$GOT_TABLE")] data [$(paste -sd' ' - <<<"$GOT_DATA")]"
fi

# ---- E3 + E4: every table readable to the end, and equal to the live rows ----
for t in "${TABLES[@]}"; do
    if ! pg_restore --data-only -t "$t" -f "$RUN_DIR/data_$t.sql" "$ARCHIVE" \
            2> "$RUN_DIR/data_$t.err"; then
        fail "E3 readable: $t - pg_restore failed: $(head -n 1 "$RUN_DIR/data_$t.err")"
        continue
    fi
    COPY_COLS=$(awk '/^COPY / {sub(/^COPY [^ ]+ /, ""); sub(/ FROM stdin;$/, ""); print; exit}' \
                  "$RUN_DIR/data_$t.sql")
    awk 'f && /^\\\.$/ {f = 0; next} f {print} /^COPY / {f = 1}' "$RUN_DIR/data_$t.sql" \
        | LC_ALL=C sort > "$RUN_DIR/archive_$t.sorted"
    pass "E3 readable: $t - columns $COPY_COLS"
    as_db env PGOPTIONS='-c default_transaction_read_only=on -c DateStyle=ISO' \
        psql -X -q -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" \
        -c "COPY public.$t TO STDOUT" > "$RUN_DIR/live_$t.copy" \
        || { fail "E4 exact: $t - could not read the live table"; continue; }
    LC_ALL=C sort "$RUN_DIR/live_$t.copy" > "$RUN_DIR/live_$t.sorted"
    N_ARCHIVE=$(wc -l < "$RUN_DIR/archive_$t.sorted" | tr -d ' ')
    N_LIVE=$(wc -l < "$RUN_DIR/live_$t.sorted" | tr -d ' ')
    H_ARCHIVE=$(hash_of "$RUN_DIR/archive_$t.sorted")
    H_LIVE=$(hash_of "$RUN_DIR/live_$t.sorted")
    if [ "$N_ARCHIVE" = "$N_LIVE" ] && [ "$H_ARCHIVE" = "$H_LIVE" ]; then
        pass "E4 exact: $t - $N_ARCHIVE rows, archive = live, sha256 $H_ARCHIVE"
    else
        fail "E4 exact: $t - archive $N_ARCHIVE rows ${H_ARCHIVE:0:12}..., live $N_LIVE rows ${H_LIVE:0:12}..."
    fi
    rm -f "$RUN_DIR/data_$t.sql" "$RUN_DIR/data_$t.err" "$RUN_DIR/archive_$t.sorted" \
          "$RUN_DIR/live_$t.copy" "$RUN_DIR/live_$t.sorted"
done

echo "------------------------------------------------------------"
echo "kept        : $(basename "$ARCHIVE"), 07_output.txt, archive_listing.txt in $RUN_DIR"
echo "not proven  : E5 (which ledger copy - Section 6) and E6 (a restore - Section 5)"
if [ ${#FAILS[@]} = 0 ]; then
    echo "BACKUP_EVIDENCE=PASS"
    exit 0
fi
echo "BACKUP_EVIDENCE=FAIL"
exit 1
