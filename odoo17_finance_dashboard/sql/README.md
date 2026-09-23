# Finance Dashboard — summary layer setup

The dashboard reads from five pre-aggregated tables. **They are not created by
the Odoo module** — run these scripts once against any database the dashboard
will point at, or it fails immediately with
`relation "finance_dashboard_daily" does not exist`.

## Run in order

```bash
export PGPASSWORD=...
PSQL="psql -h HOST -p 5432 -U USER -d DBNAME"

$PSQL -f 01_create_summary.sql              # tables, seconds
$PSQL -f 02_backfill_daily.sql              # ~1 min
$PSQL -f 03_backfill_arap.sql               # ~5-10 min, the long one
$PSQL -f 04_backfill_expense_and_derived.sql # ~2 min + indexes
$PSQL -f 05_validate.sql                    # check
```

Script 05 compares against figures verified on `gftuae_new` at 2026-03-18 for
all 10 companies. **Those expected values are specific to that database** —
on a different dataset they will not match, and you should re-establish ground
truth by running Odoo's own Balance Sheet and P&L for the same date and filters.

## What each table is for

| Table | Grain | Serves |
|-------|-------|--------|
| `finance_dashboard_daily` | (company, date) | KPI cards, P&L, sales trend, division chart |
| `finance_dashboard_arap_daily` | (company, date, maturity, partner) | top-5 overdue rankings |
| `finance_dashboard_aging_daily` | (company, date, maturity) | aging buckets (12x smaller than the above) |
| `finance_dashboard_expense_daily` | (company, date, account) | Expenses vs Last Month |
| `finance_dashboard_coverage` | (company) | refresh tracking |

## Two rules that matter

**Flow vs snapshot.** `sales`, `cogs`, `opex`, `other_income`, `depreciation` are
daily totals — SUM them over a range. Everything ending in `_delta` is a daily
*delta*: a balance "as of" a date is the cumulative sum of deltas up to it.
Summing a delta column across a range double-counts.

**History cannot be truncated.** Snapshot balances need every prior delta, so
dropping old rows silently corrupts cash, AR and AP. The pre-2024 rows are
small (~1,700 of 8,494) and exist for exactly this reason.

## Refresh

**There is no refresh job yet.** These scripts are a one-time backfill; the
tables will go stale as new entries are posted. Note also that this ledger
receives backdated entries (measured: 135 cash lines and 26 receivable lines
dated before a cutover but created after it), so a refresh cannot simply append
the latest day — it has to recompute a trailing window. `finance_dashboard_coverage.dirty_from`
exists for that purpose but nothing writes to it yet.
