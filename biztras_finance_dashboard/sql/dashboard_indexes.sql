-- Finance Dashboard - proposed indexes (DO NOT run blind)
--
-- Step E of the dashboard performance pass. These three indexes are
-- justified directly against the query shapes in models/finance_dashboard.py
-- (get_dashboard_data). Before running this:
--
--   1. Run dashboard_index_diagnostic.sql first and check whether
--      equivalent coverage already exists - Odoo core may already index
--      some of these columns individually, and Postgres can sometimes
--      combine single-column indexes well enough that a new composite
--      index isn't worth the extra write/storage cost.
--   2. Run this during a low-traffic window. CONCURRENTLY avoids taking a
--      lock that blocks writes, but it still adds I/O load while building.
--   3. CREATE INDEX CONCURRENTLY cannot run inside a transaction block, so
--      run each statement on its own (psql does this by default outside
--      an explicit BEGIN; most DB GUI tools have a "no transaction" mode
--      for exactly this case) - do not wrap this file in BEGIN/COMMIT.
--
-- Every statement is IF NOT EXISTS, so re-running this file is always
-- safe and a no-op wherever the index already exists.

-- Covers: the main balance-sheet aggregate query (cash / current assets /
-- current liabilities, unbounded on date) and the expense-by-account
-- GROUP BY query. Both filter on (company_id, parent_state='posted', date)
-- before touching account_id.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_aml_dashboard_company_state_date
    ON account_move_line (company_id, parent_state, date);

-- Covers: the open AR/AP query. Partial index - only unreconciled lines are
-- ever read by this query, and on a mature ledger those are a small
-- fraction of the table, so indexing only that subset keeps the index
-- itself small and fast to maintain as lines get reconciled over time.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_aml_dashboard_unreconciled
    ON account_move_line (company_id, account_id)
    WHERE reconciled = false;

-- Covers: the daily-sales GROUP BY query and the account_move side of the
-- sales-by-category join. Both filter on
-- (company_id, state='posted', move_type, invoice_date).
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_am_dashboard_company_state_type_date
    ON account_move (company_id, state, move_type, invoice_date);

-- --- Rollback: drop any of these independently at any time, no downtime ---
-- DROP INDEX CONCURRENTLY IF EXISTS idx_aml_dashboard_company_state_date;
-- DROP INDEX CONCURRENTLY IF EXISTS idx_aml_dashboard_unreconciled;
-- DROP INDEX CONCURRENTLY IF EXISTS idx_am_dashboard_company_state_type_date;
