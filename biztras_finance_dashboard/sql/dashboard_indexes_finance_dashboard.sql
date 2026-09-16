-- Finance Dashboard (finance_dashboard module, odoo17-finance / gftuae_new) - indexes
--
-- Justified against REAL EXPLAIN (ANALYZE) output taken 2026-09-14 against
-- gftuae_new, not assumed or copied from the earlier biztras_finance_dashboard
-- work (that project's indexes only ever covered account_move_line and were
-- designed for a different module's query shapes).
--
-- Must run each statement on its own connection/autocommit - CONCURRENTLY
-- cannot run inside a transaction block.

-- ============================================================
-- INDEX 1 - account_move_line: covers _account_balance() / _expense_total() /
-- _income_total() in finance_dashboard/controllers/main.py.
--
-- Evidence: EXPLAIN for company 7 (HORECA) showed a full Seq Scan of
-- 21,337,913 rows (cost ~1,720,517) for the cash/bank balance query - no
-- existing index supports (company_id, date) with parent_state='posted'
-- together. Company 1 used a less-bad bitmap-AND of two separate indexes,
-- but still not an index-only scan.
--
-- UP / APPLY
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_aml_fd_balance_covering
    ON account_move_line (company_id, date)
    INCLUDE (balance, account_id)
    WHERE parent_state = 'posted';

-- DOWN / ROLLBACK
-- DROP INDEX CONCURRENTLY IF EXISTS idx_aml_fd_balance_covering;

-- Safety profile: CONCURRENTLY (no lock), idempotent, no downtime.
-- Storage: proportional to posted account_move_line rows across all
-- companies - expect this to be one of the larger indexes on this table
-- given company 7 alone has ~23.8M posted lines.


-- ============================================================
-- INDEX 2 - account_move: covers _invoice_total() / _daily_sales_map() /
-- _ar_ap_moves() (top customers/suppliers, aging, total AR/AP) - NEW,
-- account_move was never indexed for this dashboard's specific query shape
-- before (the earlier biztras_finance_dashboard indexes only touched
-- account_move_line).
--
-- Evidence: EXPLAIN ANALYZE for company 1's AR query (363K move_lines,
-- only 4,936 out_invoice/out_refund moves - a SMALL company) measured
-- 12,322 ms actual execution time, almost entirely disk reads
-- (shared hit=12, read=22437 heap blocks), because the planner has to
-- bitmap-AND three separate single-column indexes (company_id, move_type,
-- invoice_date) and then revisit the heap for every candidate row. A
-- single composite index removes that heap-revisit cost for the common
-- case.
--
-- UP / APPLY
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_am_fd_company_type_state_date
    ON account_move (company_id, move_type, state, invoice_date)
    INCLUDE (payment_state, amount_residual, amount_untaxed_signed, partner_id, invoice_date_due)
    WHERE state = 'posted';

-- DOWN / ROLLBACK
-- DROP INDEX CONCURRENTLY IF EXISTS idx_am_fd_company_type_state_date;

-- Safety profile: CONCURRENTLY (no lock), idempotent, no downtime.
-- Storage: proportional to posted account_move rows (company 7 alone has
-- ~411,852 posted out_invoice/out_refund moves; total posted moves across
-- move types will be larger).


-- ============================================================
-- Verify after applying
-- ============================================================
-- SELECT indexname, pg_size_pretty(pg_relation_size(indexname::regclass))
-- FROM pg_indexes
-- WHERE indexname IN ('idx_aml_fd_balance_covering', 'idx_am_fd_company_type_state_date');
--
-- After real dashboard traffic, check idx_scan is climbing (not stuck at 0):
-- SELECT indexrelname, idx_scan FROM pg_stat_user_indexes
-- WHERE indexrelname IN ('idx_aml_fd_balance_covering', 'idx_am_fd_company_type_state_date');
