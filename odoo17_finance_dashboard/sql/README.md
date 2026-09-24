# Finance Dashboard — summary layer setup

The dashboard reads from five pre-aggregated tables. **They are not created by
the Odoo module** — run these scripts once against any database the dashboard
will point at, or it fails immediately with
`relation "finance_dashboard_daily" does not exist`.

## Run in order

**`02`, `03` and `04` must run inside ONE transaction.** `03` stages its work in a
`CREATE TEMP TABLE ... ON COMMIT DROP`; under psql's default autocommit that table
is dropped the instant it is created, and the script fails with
`ERROR: relation "arap_new" does not exist`. Running them as four separate psql
invocations — as an earlier version of this file instructed — leaves
`finance_dashboard_arap_daily` and `finance_dashboard_aging_daily` **empty** while
`daily` and `expense_daily` look fine, which is easy to miss.

`05_refresh_all.sql` exists to run all three together. Use it:

```bash
export PGPASSWORD=...
URI="postgresql://USER@HOST:PORT/DBNAME"

# 1. schema — safe standalone, and the ONLY script that may run on its own
psql "$URI" -v ON_ERROR_STOP=1 -f 01_create_summary.sql            # ~2s

# 2. all three backfills, atomically (must be run from this directory:
#    05_refresh_all.sql \i's the others by relative path)
psql "$URI" -v ON_ERROR_STOP=1 --single-transaction -f 05_refresh_all.sql
```

Measured on a ~29.9M-line ledger: `01` 2s, `02` ~95s, `04` ~77s. `03` is the long
one — against an **empty** table its incremental merge has to treat all ~500k rows
as new, which is its worst case and can exceed 20 minutes. Subsequent refreshes are
far cheaper (measured: 500 updates, 0 inserts when nothing changed).

### Run it close to the database

That single transaction is long, and it is silent while `03` inserts — no data flows
back to the client. A NAT or firewall idle timer will happily reap the socket, and
the whole transaction rolls back:

```
could not receive data from server: Operation timed out
SSL SYSCALL error: Operation timed out
connection to server was lost
```

The rollback is clean — that is the point of `--single-transaction`, and no partial
data is ever visible — but you have to start over. **Run this on the database host,
or on a machine on the same network.** If you must run it remotely, force keepalives:

```
?keepalives=1&keepalives_idle=10&keepalives_interval=5&keepalives_count=20
```

### Then check

```bash
psql "$URI" -f 05_validate.sql
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

**Refresh is `05_refresh_daily.sh`**, which runs `05_refresh_all.sql` under
`--single-transaction` + `ON_ERROR_STOP=1` and then VACUUMs on a separate connection
(VACUUM cannot run inside a transaction block). It is intended for cron at 12:30,
which is what makes the dashboard's T-1 cutoff meaningful: the previous day is
complete before the tables are rebuilt. **The cron is not enabled by these scripts** —
enabling it is a deliberate, separate step. Note also that this ledger
receives backdated entries (measured: 135 cash lines and 26 receivable lines
dated before a cutover but created after it), so a refresh cannot simply append
the latest day — it has to recompute a trailing window. `finance_dashboard_coverage.dirty_from`
exists for that purpose but nothing writes to it yet.
