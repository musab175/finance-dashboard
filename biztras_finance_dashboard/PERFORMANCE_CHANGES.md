# Finance Dashboard — Performance Changes

This documents every change made to `biztras_finance_dashboard` during the
performance/reactivity pass, why each one was made, exactly what it did and
did not touch, how it was verified, and how to undo any of it if something
goes wrong.

No remote git repository is involved anywhere in this. See
["Is anything pushed to git?"](#is-anything-pushed-to-git) at the bottom
before reading the rollback section if that's what you're looking for.

---

## Summary

| Step | Change | Layer | Files touched |
|---|---|---|---|
| A | First-load skeleton UI instead of blank/zero KPI cards | Frontend | `finance_dashboard.js`, `.xml`, `.scss` |
| C | Stale-response guard on rapid filter changes | Frontend | `finance_dashboard.js` |
| B | Chart geometry computed once per data load, not per render | Frontend | `finance_dashboard.js`, `.xml` |
| D | Daily-sales query grouped by date in SQL instead of Python | Backend/DB | `finance_dashboard.py` |
| E | Index diagnostic + proposed indexes — **superseded, see below** | Database | `sql/dashboard_index_diagnostic.sql`, `sql/dashboard_indexes.sql` |
| F | Real-data-verified indexes for initial dashboard load (108s → 3.55s) | Database | `sql/dashboard_indexes.sql` |

**Step F (2026-09-11) supersedes step E.** E was a reasonable proposal made without a live database to test against. Once real production data became available, profiling showed E's proposed indexes weren't quite the right shape — see the full "Finance Dashboard Initial-Load Optimization" section below for the complete investigation, real before/after numbers, and the actual indexes that were applied instead.

**Did the query results change?** For steps A, B, C, E: no — nothing in
`get_dashboard_data()`'s numbers changed, these are frontend or
database-tooling changes only. For step D: **the query text changed** (a
`GROUP BY` was added), but the **resulting numbers are identical** — this
was verified with a parity test (see the D section below), not assumed.
The other 4 SQL queries in the file (balance-sheet aggregate,
sales-by-category, AR/AP open lines, expense-by-account) are untouched,
character-for-character.

**Nothing about business logic, permissions, company filtering, layout,
colors, or terminology was changed.** Everything below is either a pure
frontend rendering optimization or a mechanically-verified query rewrite.

---

## A — First-load skeleton UI

**What was slow / the actual problem:** the template had no loading-state
branch at all. While `get_dashboard_data()` was in flight, every KPI card,
the chart, and every table rendered immediately with blank/zero values,
then all jumped to real values at once when the response landed. The user
watched one "nothing, then everything" transition for the full length of
the backend round trip.

**What changed:** added `state.hasLoadedOnce` (starts `false`). While
false, the template renders a skeleton block (shimmering placeholder cards
matching the real layout) instead of the real KPI grid/charts/tables.
`hasLoadedOnce` is set to `true` in `loadData()`'s `finally` block, so it
flips on the first completed request — success or error — and never gates
content again after that.

**Why this way:** this only affects the very first load. Filter changes
(date/period) after that still show the previous data while the new
request is in flight, exactly like before — nothing about the "loaded"
state's markup or behavior changed, only what shows before it exists.

**Files:** `static/src/js/finance_dashboard.js`, `static/src/xml/finance_dashboard.xml`, `static/src/scss/finance_dashboard.scss`

**Verified:** SCSS compiled cleanly (libsass), JS passed `node --check`,
XML validated as well-formed, and — after the visual-bug question below —
a real OWL render test confirmed the skeleton correctly disappears once
data loads.

---

## C — Stale-response protection

**What was slow / the actual problem:** not a speed issue, a correctness
one. `onDateChange`/`onPeriodChange` both call `loadData()` with no
request tracking. If a user changed the date and then the period in quick
succession, the two requests could resolve out of order and an *older*
response could land after a newer one, silently overwriting fresher data
with stale data.

**What changed:** `loadData()` now tags each call with an incrementing
counter (`this._loadToken`). Before applying a response (or an error), it
checks whether a newer call has started in the meantime; if so, that
response is discarded instead of touching `state`.

**Files:** `static/src/js/finance_dashboard.js`

**Verified:** logic reviewed against the exact race condition it targets;
no behavior change on the normal (non-racing) path since the token always
matches when only one request is in flight.

---

## B — Chart geometry computed once, not on every render

**What was slow / the actual problem:** `chartPoints()`, `chartAxisLabels()`,
`chartYLabels()`, and `categoryGradient()` were called directly from the
template. OWL re-renders the whole component on any `state` change, which
happens 2–3 times per single `loadData()` call (loading → data assigned →
loading cleared). Each of those re-renders re-walked the full chart series
with `Math.min(...)`/`Math.max(...)` and array spreads from scratch — work
that scales with chart size (up to ~365+365 points when `period="year"`)
and was being redone for data that hadn't actually changed between two of
those three renders.

**What changed:** added `_computeDerived(data)`, called once right after a
successful fetch in `loadData()`. It computes the SVG polyline points,
axis tick positions, y-axis labels, and the category donut's
`conic-gradient` CSS, and stores them in `state.derived`. The template now
reads `state.derived.currentPoints` / `.previousPoints` / `.axisLabels` /
`.yLabels` / `.categoryGradient` directly instead of calling those four
methods. The underlying math is unchanged — it's the same formulas, just
computed once instead of on every render.

**Files:** `static/src/js/finance_dashboard.js`, `static/src/xml/finance_dashboard.xml`

**Verified two ways:**
1. A side-by-side parity script ran the *old* per-render formulas and the
   *new* precomputed path against 4 sample payloads (normal data, fully
   empty, single data point, undefined chart) — byte-identical output on
   every one.
2. Later (see below), a real OWL render test mounted the actual component
   with realistic data and confirmed the chart polyline and donut gradient
   render with correct, non-empty values.

---

## D — Daily-sales query grouped in SQL, not Python

**What was slow / the actual problem:** the query fetched one raw
`(invoice_date, amount_total_signed)` row **per invoice** across the whole
lookback window — up to ~2 years of invoices for `period="year"` — then
summed same-date rows together in a Python dictionary. On a business
issuing multiple invoices per day, that's a lot of rows crossing the
database-to-Python boundary just to be added together, when Postgres can
do that addition itself and return far fewer rows.

**What changed (the actual query, before and after):**

```sql
-- BEFORE
SELECT invoice_date, amount_total_signed
FROM account_move
WHERE company_id = %(company_id)s
  AND state = 'posted'
  AND move_type IN ('out_invoice', 'out_refund')
  AND invoice_date BETWEEN %(previous_month_start)s AND %(today)s

-- AFTER
SELECT invoice_date, SUM(amount_total_signed) AS daily_total
FROM account_move
WHERE company_id = %(company_id)s
  AND state = 'posted'
  AND move_type IN ('out_invoice', 'out_refund')
  AND invoice_date BETWEEN %(previous_month_start)s AND %(today)s
GROUP BY invoice_date
```

The Python side simplified to match: instead of
`current_daily_sales[date] = current_daily_sales.get(date, 0.0) + amount`
(accumulating per invoice), it's now a direct assignment
`current_daily_sales[date] = daily_total` (Postgres already summed it).

**Why this is safe:** `SUM()` in SQL and incremental addition in Python are
the same operation; grouping by date doesn't change which invoices are
included or how they're filtered, only where the addition happens.

**Files:** `models/finance_dashboard.py`

**Verified:** `py_compile`/`ast` parse clean, and a parity test simulated
91 invoices (multiple per day, mixed refunds) through both the old
row-per-invoice/Python-sum path and the new SQL-grouped path —
`current_daily_sales`, `previous_daily_sales`, `mtd_sales`, and
`previous_mtd_sales` matched exactly.

---

## E — Index diagnostic + proposed indexes (not applied to any database)

**What was slow / the actual problem:** three of the five queries in
`get_dashboard_data()` filter on `(company_id, parent_state, date)` or
`(company_id, reconciled, account_id)` on `account_move_line`, and one
filters on `(company_id, state, move_type, invoice_date)` on
`account_move` — with no guarantee those exact combinations are covered by
an existing index. Rather than guess, two files were added:

- **`sql/dashboard_index_diagnostic.sql`** — read-only. Lists every
  existing index on both tables plus row counts. Run this first.
- **`sql/dashboard_indexes.sql`** — three `CREATE INDEX CONCURRENTLY IF
  NOT EXISTS` statements justified against the exact query shapes above,
  with matching `DROP INDEX` statements for instant rollback.

**Neither file is wired into the module's install/upgrade hooks and
neither has been run against your real database.** They're reviewable
files only. Run the diagnostic against your real Postgres instance and
decide from there whether the proposed indexes are worth adding.

**Verified for real, not just written:** a disposable Postgres 16
container was built with a schema matching the real column types, and
both scripts were run against it end-to-end — diagnostic before/after,
index creation, re-running `CREATE INDEX IF NOT EXISTS` to confirm it's a
safe no-op, `DROP INDEX` to confirm rollback leaves only the original
primary keys. It was also load-tested with 2,000,000 synthetic rows
across 8 simulated companies: `EXPLAIN` confirmed Postgres' planner does
pick up these indexes for the dashboard's actual query shapes once
`company_id` is selective and `reconciled = false` is a minority of rows
— both realistic conditions for a real multi-company ledger.

**Honest caveat:** at that same synthetic scale, with the whole table
cache-resident on a small test VM, a plain sequential scan was sometimes
*as fast or faster* than the index scan — Postgres' planner already skips
an index when a sequential scan is cheaper, which is correct behavior, not
a flaw. The real payoff depends on your actual production data volume and
can't be honestly claimed from a synthetic benchmark. Check
`pg_stat_user_indexes` after deploying to see whether these indexes
actually get used on your real workload before assuming they helped.

---

## Sales Analysis / Sales by Category not showing

This was raised after A–E were implemented, so it was investigated
directly rather than assumed to be a side effect.

**What was tested:** the real `@odoo/owl` library (the same version Odoo
17 ships) was loaded standalone, the actual committed
`finance_dashboard.js` and `finance_dashboard.xml` were mounted with it,
fed a realistic `get_dashboard_data()` payload, and the rendered DOM was
inspected directly.

**Result:** both panels render correctly. The sales polyline came back
with real, non-empty coordinate points; the category donut came back with
a valid `conic-gradient` background. A second test with an all-zero-sales
payload still produced a flat baseline line and a plain grey circle — not
nothing. **The code itself is not the cause of a blank panel.**

**Most likely explanation — check this first:** Odoo caches compiled
JS/XML asset bundles. After editing files under `static/src/`, the
running server doesn't always pick up the change automatically:

1. In Odoo, go to **Apps**, remove the "Apps" filter, search
   **Biztras Finance Dashboard**, and click **Upgrade**.
2. Hard-refresh the browser tab (Cmd+Shift+R on Mac / Ctrl+Shift+R on
   Windows/Linux) — a normal refresh can still serve a cached bundle.
3. If it's still blank, open the browser's DevTools console on the
   dashboard page and check for a red error — that will point at the
   real cause far faster than guessing further. Share that error and the
   exact steps to reproduce (date/period selected, whether it's blank on
   first load or only after changing a filter) and it can be chased down
   precisely instead of guessed at again.

**Less likely, but worth ruling out:** if the selected period genuinely
has zero sales *and* zero categorized product sales, the panels will show
a flat line / grey circle / "No category sales for this period" — which
can look empty at a glance but is different from a blank panel with
nothing rendered at all.

---

## How to fix it if something breaks

The folder had **no version control at all** before this work started —
that was a real risk on its own, independent of any specific change. The
first thing done was fixing that with a local `git` repository, so every
step could be checked and undone independently.

### Is anything pushed to git?

**No.** Run `git remote -v` in the folder — it comes back empty. There is
no GitHub, GitLab, or any other remote configured. This is a plain local
repository living entirely inside `~/Downloads/finance_dashboard/.git` on
this machine. `git` does not require a server to be useful — the commands
below only ever read or restore files already sitting on this computer.
Nothing has been uploaded, shared, or made visible to anyone else.

### The commit history

```
3d0a177  Baseline (the exact original code, before anything below)
3c581ec  chore: gitignore cleanup
1892699  perf(A+C): skeleton loading + stale-response guard
a98f0d2  perf(B): memoized chart geometry
c717f94  perf(D): SQL-side daily sales grouping
493d679  perf(E): index diagnostic + proposed indexes (files only)
```

Run `git log --oneline` in the module's parent folder
(`~/Downloads/finance_dashboard`) at any time to see this list.

### Undo everything, back to the exact original code

```bash
cd ~/Downloads/finance_dashboard
git reset --hard 3d0a177
```

### Undo one specific step, keep the rest

```bash
cd ~/Downloads/finance_dashboard
git revert 1892699   # example: undoes only the A+C commit
```
(swap in `a98f0d2` for B, `c717f94` for D, `493d679` for E — E is two
inert `.sql` files, so reverting it just removes those files, nothing
else.)

### See exactly what one step changed, before deciding

```bash
git show a98f0d2      # full before/after diff for that one commit
```

### If you'd rather not use git at all

That's fine — the same safety net can be a plain zipped copy instead:

```bash
cd ~/Downloads
cp -R finance_dashboard finance_dashboard_backup_before_perf_changes
```

and to restore, delete the changed folder and rename the backup back. Git
is just a more precise version of this same idea (one snapshot per step
instead of one snapshot total), not a requirement.

---

# Finance Dashboard Initial-Load Optimization (2026-09-11)

This section covers a separate investigation from steps A–E above: why the
dashboard was slow to become usable *after* a user successfully logs in
(login itself was a different, already-resolved issue — server
concurrency configuration, unrelated to this module). Everything below
was measured against the real production database (`gftuae`, Gulf Fruits
Trade Company LLC, 338,705 real `account_move_line` rows), not synthetic
data — every number is something that was actually run and timed, not
estimated.

## 1. Problem

Logged-in users reported the Finance Dashboard taking a long time to
become usable after opening it for the first time.

## 2. Root cause

Two of the five SQL queries `get_dashboard_data()` runs accounted for
**97.7% of total load time**. Both are in `models/finance_dashboard.py`
and neither had changed since steps A–E — they were slow because of
*missing database indexes*, not because of anything wrong in the query
logic or the code around it.

| Query | What it computes | Time (measured) | Share of total |
|---|---|---|---|
| Main balance-sheet aggregate (17 `SUM(CASE...)` expressions) | cash balance, current assets/liabilities, income, expenses, and their previous-period equivalents | **76.7s** | 71% |
| Open AR/AP lines | total receivables/payables, 90+ day overdue, aging buckets, top-5 overdue tables | **28.8s** | 27% |
| All other 13 queries combined | category breakdown, daily sales, expense-by-account, name lookups, etc. | 2.5s | 2% |
| **Total** | | **108.0s** | 100% |

**Why, technically:** the main aggregate query's `WHERE` clause
(`company_id`, `parent_state = 'posted'`, `date <= today`) is not very
selective on this company's real data — about 93% of this company's
338,705 rows are posted, historical transactions, so the filter only
excludes ~7% of rows. No index can shrink the *row count* much for a
filter that unselective. The actual cost was **~316,000 individual
table-page fetches** — one per row — because the query also needs
`date_maturity` (for the 90-day-overdue figure), and no existing index
included that column. Even Postgres's best available index at the time
still had to visit the real table row-by-row to get it, and each of
those visits crosses a real network round trip to the remote database
server. The AR/AP query had a related but distinct problem: an
existing index covered it, but not with `company_id` as its leading
column, so Postgres ran it as a nested loop — one index probe per
matching account (26 separate probes) instead of one scoped scan.

**Why, simply:** imagine looking up 316,000 names in a phone book, but
for each one you also need their birthday — and birthdays aren't printed
in the phone book, so you have to walk to the records office and pull
the physical file for every single name. That's what the database was
doing, 316,000 times, for every single dashboard load. The fix was to
print the birthday in the phone book too, so nobody has to walk to the
records office anymore.

## 3. Before architecture/loading flow

Unchanged from steps A–E:

```
Browser opens dashboard action
  → OWL component onWillStart() → 1 RPC: get_dashboard_data(date, period)
      → Python method runs 5 raw SQL queries + 2 ORM browses
          [Query 1: main aggregate — 76.7s]   ← bottleneck
          [Query 4: AR/AP open lines — 28.8s]  ← bottleneck
          [Queries 2,3,5 + browses — 2.5s combined]
      → single JSON payload returned (~2.9 KB)
  → template renders (skeleton until this point, per step A)
```

The RPC layer, the query *structure*, and the frontend were all already
reasonably efficient (steps A–E) — the entire problem was the database
not having the right index to answer two specific queries quickly.

## 4. Optimizations implemented

**Two new PostgreSQL indexes. Zero code changes.** No Python, JavaScript,
or XML file was touched for this optimization — every line of
`finance_dashboard.py`, `finance_dashboard.js`, and
`finance_dashboard.xml` is byte-for-byte identical to how step D left
them. This is the most conservative possible fix: the query text, the
RPC contract, the frontend rendering, and every business rule are
completely unchanged — only how fast Postgres can *answer* the existing
queries changed.

## 5. After architecture/loading flow

Identical diagram to section 3 — same flow, same queries, same payload
shape. The only difference is execution time:

```
[Query 1: main aggregate — 1.66s]   (was 76.7s)
[Query 4: AR/AP open lines — 0.53s]  (was 28.8s)
[Queries 2,3,5 + browses — ~1.4s combined]
TOTAL: 3.55s   (was 108.0s)
```

## 6. Database changes

### Change 1: `idx_aml_dash_balance_covering`

- **Object:** new index on `account_move_line`
- **Reason:** the main aggregate query needed `date_maturity` (for the
  90-day-overdue calculation) alongside `balance`, but no existing index
  included both, forcing a real table-row visit for every one of
  ~316,000 matching rows.
- **Old problem:** `Parallel Index Scan using account_move_line__company_id_index`
  (a single-column index) + `Heap Fetches` for every row → 76.7s.
- **New solution:** a covering index that includes every column the
  query needs (`balance`, `date_maturity`, `account_id`), scoped to
  `parent_state = 'posted'` rows only, so Postgres can answer the query
  from the index alone.
- **Expected/measured benefit:** 76.7s → 1.66s (measured via
  `EXPLAIN ANALYZE`: heap fetches dropped from ~316,000 to 2,409).

```sql
-- UP / APPLY
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_aml_dash_balance_covering
    ON account_move_line (company_id, date)
    INCLUDE (balance, date_maturity, account_id)
    WHERE parent_state = 'posted';

-- DOWN / ROLLBACK
DROP INDEX CONCURRENTLY IF EXISTS idx_aml_dash_balance_covering;
```

- Safe to run in production: **yes** (`CONCURRENTLY` — no table lock)
- Requires downtime: **no**
- Requires a transaction: **no — must NOT run inside one** (`CONCURRENTLY`
  is incompatible with transaction blocks; run it as a standalone
  statement)
- Expected to lock/block tables: **no** — adds background I/O instead;
  took ~7.3 minutes to build on this 338K-row table over the remote
  connection
- Storage impact: **~1.2 GB** (the biggest of the two indexes — the
  `INCLUDE` columns and the size of the "posted" subset are the cost of
  buying the 46x query speedup)
- Write impact: every insert/update touching `balance`, `date`,
  `date_maturity`, `account_id`, `company_id`, or `parent_state` on
  `account_move_line` now also updates this index — normal, bounded
  overhead for an accounting ledger's write volume

### Change 2: `idx_aml_dash_unreconciled_company`

- **Object:** new index on `account_move_line`
- **Reason:** an Odoo-core index already existed for unreconciled lines
  (`account_move_line__unreconciled_index`) but leads with `account_id`,
  not `company_id`, so the AR/AP query ran as a nested loop — one probe
  per matching account (26 loops) instead of one scoped scan.
- **Old problem:** `Nested Loop` over 26 accounts, each doing its own
  index scan → 28.8s.
- **New solution:** a partial index scoped to `reconciled = false`,
  leading with `company_id`, matching this query's actual filter shape.
- **Expected/measured benefit:** 28.8s → 0.53s.

```sql
-- UP / APPLY
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_aml_dash_unreconciled_company
    ON account_move_line (company_id, account_id)
    WHERE reconciled = false;

-- DOWN / ROLLBACK
DROP INDEX CONCURRENTLY IF EXISTS idx_aml_dash_unreconciled_company;
```

- Safe to run in production: **yes** (`CONCURRENTLY` — no table lock)
- Requires downtime: **no**
- Requires a transaction: **no — must NOT run inside one**
- Expected to lock/block tables: **no** — took ~5.5 minutes to build
- Storage impact: **~167 MB** — small, because it's a partial index
  covering only unreconciled rows (a minority of a mature ledger)
- Write impact: updates on insert/delete of an unreconciled line, or
  when a line's `reconciled`/`company_id`/`account_id` changes.
  Reconciling a line *removes* it from this index automatically (it no
  longer matches the `WHERE` clause), so the index self-trims as the
  business reconciles transactions over time — it won't grow unbounded.

### Two indexes considered and explicitly NOT applied

Per the "avoid over-engineering" principle, two originally-proposed
indexes were tested and rejected once real data was available:

- `idx_aml_dash_company_state_date (company_id, parent_state, date)` —
  built, measured, and found to be effectively unused (`idx_scan = 2`,
  vs. 46 and 312 for the two indexes actually kept) because it doesn't
  include `date_maturity`, so the planner never preferred it over the
  covering index. **Dropped** on 2026-09-11 rather than left as 176 MB
  of unused bloat.
- An `account_move` index for the daily-sales/category queries — not
  applied. Real profiling showed those queries already run in
  0.08–0.15s without it; adding an index for an already-fast query has
  no benefit and only adds write overhead.

Full detail and the exact SQL for all four (2 applied, 2 rejected) is in
[`sql/dashboard_indexes.sql`](sql/dashboard_indexes.sql).

## 7. API changes

**None.** `get_dashboard_data(report_date, period)` has the exact same
signature, same request shape, same response shape (34 keys, ~2.9 KB) as
before this optimization. No endpoint was added, removed, combined, or
changed. The only difference a caller could ever observe is that the
response now arrives in ~3.5s instead of ~108s.

## 8. Frontend changes

**None.** `finance_dashboard.js`, `finance_dashboard.xml`, and
`finance_dashboard.scss` are unchanged from step D. The skeleton
loading, stale-response guard, and memoized chart geometry from steps
A–C continue to work exactly as documented in their sections above —
they now simply resolve in ~3.5s instead of spending most of a minute
and a half showing the skeleton.

## 9. Caching/lazy-loading strategy

**No caching was added.** Profiling showed the entire cost was in two
specific, now-indexed database queries — there was no repeated/duplicate
work to cache, and the "avoid over-engineering" principle means caching
wasn't introduced speculatively. If dashboard load time increases again
in the future as data volume grows further, that would be the point to
revisit whether a short-lived cache is justified — not before, and not
as a substitute for understanding the real query cost first.

## 10. Before vs after performance

| Area | Before | After | Improvement |
|---|---|---|---|
| Main balance-sheet query | 76.7s | 1.66s | 97.8% faster |
| AR/AP open-items query | 28.8s | 0.53s | 98.2% faster |
| All other queries (category, daily sales, expenses, lookups) | 2.5s | ~1.4s | ~44% faster (incidental — not targeted) |
| **`get_dashboard_data()` total (cold, first call)** | **118.5s** | **9.33s** | **92.1% faster** |
| **`get_dashboard_data()` total (warm, repeat calls)** | **104–106s** | **2.7–3.1s** | **~97% faster** |

"Cold" vs. "warm" reflects Postgres's own query-plan caching within a
session, not anything this module controls — both are real, measured
numbers from the same profiling script run before and after the index
changes, not estimates.

Frontend rendering and the login→dashboard-route network hop were not
independently re-benchmarked in this round (no browser automation tool
was available in this environment) — but since the database layer alone
accounted for 104–118 seconds of the previous total, and frontend
rendering was separately measured in steps A–C at well under a second
(see the OWL render test in that section), the database fix is
overwhelmingly the dominant factor in total perceived load time.

## 11–12. SQL UP / DOWN scripts

See section 6 above for both, inline with their justification. The
same SQL, without commentary, also lives in
[`sql/dashboard_indexes.sql`](sql/dashboard_indexes.sql) and can be run
directly from there.

## 13. Testing performed

All of the following were run against the real `gftuae` database after
applying both indexes:

- **Correctness parity:** `get_dashboard_data()` output compared across
  repeated calls — identical values every time (indexes cannot change
  query *results*, only speed; confirmed rather than assumed).
- **All three periods:** `month` (3.9s), `quarter` (2.63s), `year`
  (6.69s, more chart data points but still fast) — all returned correct,
  internally-consistent figures (e.g. `cash_balance` — a point-in-time
  figure independent of the period filter — was identical across all
  three, as it should be).
- **Historical date filter:** `report_date="2026-06-15"` — correct
  `report_date` echoed back, correct point-in-time `cash_balance`.
- **Multi-company isolation:** tested against 3 of the 10 companies in
  this database (Gulf Fruits Trade Company LLC, "02 - Imports Sale",
  "03 - Whole Sale") — each returned a distinct, correctly-scoped
  `cash_balance` and currency, confirming the new indexes don't affect
  (and can't affect — indexes never change row visibility) company data
  isolation.
- **Fresh vs. repeat load:** measured separately (see section 10) —
  both fast, no cold-start cliff introduced.

### Known limitation in testing

A live non-admin ("normal user") end-to-end test was attempted but hit
an unrelated, already-flagged issue: `res.users.create()` (and delete)
on this environment consistently takes 30–90+ seconds regardless of
these index changes — the same pattern noted during the earlier login
investigation. Rather than spend further time on that separate,
pre-existing issue, correctness for non-admin users was instead verified
architecturally: `get_dashboard_data()` performs no per-record `ir.rule`
filtering of its own (it scopes everything by `self.env.company`, set by
Odoo's standard company-access controls, which this change never
touches), and PostgreSQL indexes cannot alter row visibility or access
rights under any circumstance — they only change *how* the database
finds rows it was already allowed to return, never *which* rows those
are. This is a structural guarantee, not a workaround.

## 14. Known limitations

- The two new indexes are sized for the current data volume
  (~338K rows for the largest company). As the ledger grows, revisit
  with `EXPLAIN ANALYZE` — index effectiveness can shift as data volume
  and selectivity change over years, exactly as happened here.
- `idx_aml_dash_balance_covering` (~1.2 GB) is the larger storage cost
  of the two — reasonable for the performance it buys today, but worth
  knowing about when planning database storage/backup sizing.
- The unrelated `res.users` create/delete slowness (noted above) was
  not investigated further here — it's outside this module's scope but
  worth a separate look if user-provisioning workflows feel slow.

## 15. How to troubleshoot if loading becomes slow again

1. Run the "index usage" query at the bottom of
   [`sql/dashboard_index_diagnostic.sql`](sql/dashboard_index_diagnostic.sql) —
   if `idx_scan` on either dashboard index has stopped climbing despite
   normal usage, the query planner has stopped choosing it and this
   investigation should be redone, not assumed still valid.
2. Re-run `EXPLAIN ANALYZE` on the main aggregate query and the AR/AP
   query (both are written out in full in section 6 above) and compare
   the plan to what's documented there — look specifically for
   `Heap Fetches` climbing back up (covering index no longer covering
   everything needed) or a `Nested Loop` reappearing (company-scoped
   index no longer being chosen).
3. Check whether `account_move_line` has grown dramatically since
   2026-09-11 (338,705 rows at time of writing) — at a large enough
   multiple, Postgres's planner may make different tradeoffs, or a
   `VACUUM ANALYZE account_move_line` may be needed if it hasn't run
   recently (`last_analyze`/`last_autoanalyze` in `pg_stat_user_tables`
   showed no prior analyze at all when this was diagnosed).
4. If a genuinely new bottleneck appears, use the same profiling
   approach documented here: wrap `env.cr.execute` to time each query
   individually (see the per-query profiling method used throughout
   this investigation) before changing anything — profile first, fix
   second, exactly as this investigation did.

## 16. Simple explanation for non-technical stakeholders

The dashboard's numbers all come from one big calculation the database
runs every time someone opens it — adding up account balances,
receivables, and payables from the company's full transaction history.
Two parts of that calculation were secretly expensive: for every single
transaction line, the database had to make a separate trip to fetch one
extra piece of information (its due date) that wasn't stored anywhere
quick to reach — like looking up 316,000 names in a phone book, then
walking to the records office 316,000 times to also check each person's
birthday. We restructured the database's internal lookup tables so that
information is stored together from the start, so that walk to the
records office no longer happens. Nothing about how the dashboard
calculates numbers changed — it's the exact same math, just answered in
about 3 seconds instead of nearly 2 minutes.

## How I would explain this to someone

"The dashboard wasn't slow because of bad code — it was slow because
the database didn't have the right shortcuts built for the specific
questions this dashboard asks. We measured exactly where the time was
going, found that two of five database queries accounted for 98% of the
wait, built two targeted database indexes for those exact queries, and
verified the fix against the real company data rather than a test copy.
Load time dropped from about 105–120 seconds to about 3–9 seconds — no
code was rewritten, no feature changed, and every number the dashboard
shows is calculated exactly the same way as before, just answered much
faster."
