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
| E | Index diagnostic + proposed indexes (not applied anywhere) | Database | `sql/dashboard_index_diagnostic.sql`, `sql/dashboard_indexes.sql` |

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
