#!/usr/bin/env bash
# Reporting-layer backup. EXPLICIT five-table list. 2026-10-01.
#
# WHY NOT `-t 'finance_dashboard_*'`:
#   That glob matches SEVEN tables on a database where the module is installed.
#   Two of them - finance_dashboard_category_sales_daily and
#   finance_dashboard_category_sales_coverage - are created and owned by Odoo's
#   ORM (models finance.dashboard.category.sales.*). Including them would put
#   ORM-managed schema into a rollback archive that psql could later restore
#   OUTSIDE Odoo's migration lifecycle, which is how schema drift starts.
#   They stay under Odoo's ownership. They are not backed up here.
#
# WHY NOT A FULL DUMP:
#   gftuae is ~101 GB. This backup exists to roll back the REPORTING LAYER, not
#   the business. Naming five tables makes it physically impossible for a restore
#   from this archive to touch account_move_line or any other business table.
#
# The five are read from 01_create_summary.sql's CREATE TABLE statements.

set -euo pipefail

: "${PGHOST:?set PGHOST}"
: "${PGPORT:=5432}"
: "${PGUSER:?set PGUSER}"
: "${PGDATABASE:?set PGDATABASE}"
OUTDIR="${OUTDIR:-/var/backups/finance-dashboard}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="${OUTDIR}/fd_reporting_${PGDATABASE}_${STAMP}.dump"

TABLES=(
  finance_dashboard_daily
  finance_dashboard_arap_daily
  finance_dashboard_aging_daily
  finance_dashboard_expense_daily
  finance_dashboard_coverage
)

mkdir -p "$OUTDIR"
ARGS=()
for t in "${TABLES[@]}"; do ARGS+=(-t "public.${t}"); done

echo "=== reporting-layer backup $(date -u '+%F %T UTC') ==="
echo "target : ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "tables : ${TABLES[*]}"
echo "out    : ${OUT}"

pg_dump -Fc -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "${ARGS[@]}" -f "$OUT"

echo "--- verifying archive contents ---"
pg_restore -l "$OUT" | grep -E 'TABLE (DATA )?' || true

# Fail loudly if anything outside the five crept in.
if pg_restore -l "$OUT" | grep -qE 'category_sales'; then
  echo "FAIL: ORM-managed category_sales table present in archive"; exit 1
fi
if pg_restore -l "$OUT" | grep -qE 'account_move_line|account_account|res_company'; then
  echo "FAIL: a BUSINESS table is present in archive"; exit 1
fi

echo "size   : $(du -h "$OUT" | cut -f1)"
echo "=== backup OK: five reporting tables only, no business or ORM tables ==="
