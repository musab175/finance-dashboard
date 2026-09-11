-- Finance Dashboard - database indexes for get_dashboard_data()
--
-- STATUS AS OF 2026-09-11: two of these are APPLIED (verified against the
-- real gftuae production data, ~338K account_move_line rows for Gulf
-- Fruits Trade Company LLC), one was proposed and superseded, one was
-- evaluated and found unnecessary. Read the STATUS line on each block
-- before assuming anything here still needs to run - see
-- PERFORMANCE_CHANGES.md, section "Finance Dashboard Initial-Load
-- Optimization" for the full investigation and real before/after numbers.
--
-- General notes for anything you do run from this file:
--   1. CREATE/DROP INDEX CONCURRENTLY cannot run inside a transaction
--      block - run each statement on its own connection/autocommit,
--      never wrapped in BEGIN/COMMIT.
--   2. CONCURRENTLY does not lock the table against reads or writes, but
--      it does add real I/O load while building - on this environment
--      (remote DB, ~338K rows) each CONCURRENTLY build took 5-7 minutes.
--   3. Every statement is IF NOT EXISTS / IF EXISTS, so re-running this
--      file is always safe.

-- ============================================================
-- INDEX 1 - APPLIED (2026-09-11) - idx_aml_dash_balance_covering
-- ============================================================
-- Covers: the main balance-sheet aggregate query in get_dashboard_data()
-- (cash_balance / current_assets / current_liabilities / expenses /
-- income and their previous-period equivalents - 17 SUM(CASE...)
-- expressions over account_move_line JOIN account_account).
--
-- Why this exact shape: the query's WHERE clause
-- (company_id, parent_state='posted', date <= today) is NOT very
-- selective on this data (this company's ledger is ~93% posted,
-- historical rows - the filter removes only ~7% of rows). No index
-- can shrink the row count much. What WAS costing 70+ seconds was
-- ~316,000 heap fetches - one per row - because the query also needs
-- l.date_maturity (for the 90+-day-overdue figure), and no existing
-- index included that column, so even a "good" index still forced a
-- full table touch per row, over a real network round trip per fetch.
-- Including every column the query needs turns this into a true
-- index-only scan (verified: heap fetches dropped from ~316,000 to
-- 2,409 - just the rows that had been touched since the last VACUUM).
--
-- UP / APPLY
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_aml_dash_balance_covering
    ON account_move_line (company_id, date)
    INCLUDE (balance, date_maturity, account_id)
    WHERE parent_state = 'posted';

-- DOWN / ROLLBACK
-- DROP INDEX CONCURRENTLY IF EXISTS idx_aml_dash_balance_covering;

-- Safety profile:
--   Safe to run in production: yes (CONCURRENTLY, no lock)
--   Requires downtime: no
--   Requires a transaction: no - must NOT run inside one
--   Expected to lock/block tables: no (CONCURRENTLY skips the
--     ACCESS EXCLUSIVE lock a plain CREATE INDEX would take; it adds
--     background I/O instead, run it off-peak on a busy production DB)
--   Storage impact: ~1.2 GB on this dataset (INCLUDE columns and the
--     "posted" partial-index population make this the biggest of the
--     three indexes here - the tradeoff that buys the 30-40x query win)
--   Write impact: every INSERT/UPDATE that touches balance, date,
--     date_maturity, account_id, company_id, or parent_state on
--     account_move_line now also updates this index. Normal, bounded
--     overhead for an accounting ledger's write volume - not a
--     hot/high-frequency table in the way e.g. a queue table would be.


-- ============================================================
-- INDEX 2 - APPLIED (2026-09-11) - idx_aml_dash_unreconciled_company
-- ============================================================
-- Covers: the open AR/AP query (total_receivables / total_payables /
-- overdue_90 / aging buckets / top-5 overdue tables).
--
-- Why this exact shape: an equivalent Odoo-core index already exists
-- (account_move_line__unreconciled_index, on (account_id, partner_id))
-- but doesn't lead with company_id, so the planner was doing a nested
-- loop - one index probe per matching account (26 loops on this data) -
-- instead of a single scoped scan. Leading with company_id lets
-- Postgres go straight to this company's unreconciled rows in one pass.
--
-- UP / APPLY
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_aml_dash_unreconciled_company
    ON account_move_line (company_id, account_id)
    WHERE reconciled = false;

-- DOWN / ROLLBACK
-- DROP INDEX CONCURRENTLY IF EXISTS idx_aml_dash_unreconciled_company;

-- Safety profile:
--   Safe to run in production: yes (CONCURRENTLY, no lock)
--   Requires downtime: no
--   Requires a transaction: no - must NOT run inside one
--   Expected to lock/block tables: no
--   Storage impact: ~167 MB on this dataset (partial index - only
--     unreconciled rows are included, which is why it stays small even
--     though the table has 338K+ rows)
--   Write impact: updates when a line's reconciled/company_id/account_id
--     changes, or on insert/delete of an unreconciled line. Reconciling
--     a line REMOVES it from this index (it fails the WHERE clause),
--     which keeps the index self-trimming over time.


-- ============================================================
-- INDEX 3 - PROPOSED, THEN SUPERSEDED - do not apply
-- ============================================================
-- This was the original candidate for the main aggregate query,
-- proposed before real production data was available to test against.
-- It WAS built and measured on 2026-09-11: idx_scan stayed at 2 after
-- real dashboard traffic (vs. 46 and 312 for the two indexes above),
-- because the planner never chose it over the covering index - it
-- doesn't include date_maturity, so it still requires a heap fetch per
-- row, which is the actual cost driver (see Index 1's explanation).
-- It was DROPPED on 2026-09-11 to avoid paying its ~176 MB storage and
-- write-maintenance cost for zero real benefit. Kept here only as a
-- record of what was tried and why it didn't help - do not recreate it.
--
-- (would have been)
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_aml_dash_company_state_date
--     ON account_move_line (company_id, parent_state, date);
-- DROP INDEX CONCURRENTLY IF EXISTS idx_aml_dash_company_state_date;


-- ============================================================
-- INDEX 4 - EVALUATED, NOT NEEDED - do not apply
-- ============================================================
-- Originally proposed to cover the daily-sales GROUP BY query and the
-- account_move side of the sales-by-category join on account_move
-- (company_id, state, move_type, invoice_date). Real profiling on
-- 2026-09-11 showed both queries already run in 0.08-0.15s on production
-- data without this index - they were never the bottleneck (the two
-- account_move_line queries above accounted for 97.7% of total time).
-- Not applied: adding an index with no measured benefit is exactly the
-- unnecessary indexing this file's own review process exists to avoid.
--
-- (would have been, if ever justified by future profiling)
-- CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_am_dashboard_company_state_type_date
--     ON account_move (company_id, state, move_type, invoice_date);
-- DROP INDEX CONCURRENTLY IF EXISTS idx_am_dashboard_company_state_type_date;
