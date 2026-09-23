#!/usr/bin/env bash
# Finance Dashboard reporting-layer refresh (T-1 policy, full rebuild).
#
# WHEN: once a day, AFTER 12:00 local time.
#   The dashboard reports through YESTERDAY. Running after noon lets the
#   morning's back-dated entries land, so yesterday's figures have settled
#   before the snapshot is taken. The noon rule governs WHEN the snapshot is
#   taken - it is NOT a transaction cutoff. Nothing here filters on create_date;
#   period membership is decided purely by account_move_line.date.
#
# STRATEGY: full rebuild, deliberately. A rolling window was rejected because
#   edits reach back a median of 76 days and up to 855; true incremental was
#   deferred because accounting-date changes and deletions leave stale rows
#   that only a periodic full rebuild heals. See 03 - Decisions.
#
# ATOMICITY: stages 02/03/04 plus the coverage stamp run as ONE transaction via
#   05_refresh_all.sql. Any failure rolls the whole thing back, so the reporting
#   layer only ever moves between complete vintages.
#
# BLOAT: 03 replaces ~493k rows every run, leaving that many dead tuples.
#   VACUUM cannot run inside a transaction block, so it runs on a SEPARATE
#   connection after COMMIT. Plain ANALYZE remains inside the transaction.
#
# Credentials come from ~/.pgpass (chmod 600) - never on the command line,
# where they would be visible in the process table.
#
# Example crontab (12:30 daily) - NOT YET ENABLED:
#   30 12 * * *  /path/to/05_refresh_daily.sh >> /var/log/fd_refresh.log 2>&1

set -euo pipefail

: "${PGHOST:?set PGHOST}"
: "${PGPORT:=5432}"
: "${PGUSER:?set PGUSER}"
: "${PGDATABASE:?set PGDATABASE}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URI="postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}?keepalives=1&keepalives_idle=20&keepalives_interval=5&keepalives_count=3&connect_timeout=25"

CUTOFF=$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d')
echo "=== Finance Dashboard refresh $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "target : ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "cutoff : dashboard will report through ${CUTOFF} (T-1)"

HOUR=$(date '+%H')
if [ "${HOUR#0}" -lt 12 ]; then
  echo "WARNING: running before 12:00 - yesterday's back-dated entries may not have settled."
fi

# ---- Stage 1: the refresh, as ONE transaction -------------------------------
echo "--- refresh (single transaction) ---"
start=$(date +%s)
( cd "${HERE}" && psql "$URI" -v ON_ERROR_STOP=1 --single-transaction -f 05_refresh_all.sql )
echo "    committed in $(( $(date +%s) - start ))s"

# ---- Stage 2: reclaim bloat, AFTER commit -----------------------------------
# Must be a separate connection: "VACUUM cannot run inside a transaction block".
# arap_daily is the one that matters (~493k dead tuples per run); the others are
# upserts and churn far less.
echo "--- vacuum (separate connection, post-commit) ---"
start=$(date +%s)
psql "$URI" -v ON_ERROR_STOP=1 \
  -c "VACUUM (ANALYZE) finance_dashboard_arap_daily;" \
  -c "VACUUM (ANALYZE) finance_dashboard_aging_daily;" \
  -c "VACUUM (ANALYZE) finance_dashboard_daily;" \
  -c "VACUUM (ANALYZE) finance_dashboard_expense_daily;"
echo "    vacuum done in $(( $(date +%s) - start ))s"

# ---- Report the vintage the dashboard will now advertise --------------------
psql "$URI" -P pager=off -c \
  "SELECT MAX(last_refresh_at) AS refreshed_at,
          bool_and(last_refresh_ok) AS all_ok,
          COUNT(*) AS companies
     FROM finance_dashboard_coverage;"

echo "=== refresh complete $(date '+%Y-%m-%d %H:%M:%S') ==="
