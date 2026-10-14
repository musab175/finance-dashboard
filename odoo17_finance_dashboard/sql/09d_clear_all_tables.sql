-- SECTION 5: EMPTY ALL FIVE REPORTING TABLES BEFORE A RESTORE LOADS THEM.
-- 2026-10-14.
--
-- RUN ONLY BY 09b_restore_transaction.py, inside its single restore transaction,
-- after the identity check and before the archive's rows are loaded. Never on its
-- own: run outside that transaction it would leave the dashboard with no data.
--
-- ALL FIVE, unlike 12b: a restore replaces the whole layer with the archive's
-- rows, ids included, so every current row must go first or a restored id would
-- collide with a current one.
--
-- DELETE, NOT TRUNCATE (the same reasons as 12b): DELETE takes row locks only.
-- Other sessions keep seeing the previous rows until COMMIT, and a ROLLBACK leaves
-- them exactly as they were. TRUNCATE would take an ACCESS EXCLUSIVE lock until
-- the end of the transaction, and TRUNCATE ... RESTART IDENTITY would also reset
-- the id sequences, which a restore never touches.
--
-- Schema-qualified: the driver connects as postgres, not through Odoo, so the
-- names must not depend on that session's search_path.
--
-- Executed without parameters: no percent sign anywhere in this file, comments
-- included (see 06b_validate_live_inline.sql).
DELETE FROM public.finance_dashboard_daily;
DELETE FROM public.finance_dashboard_arap_daily;
DELETE FROM public.finance_dashboard_aging_daily;
DELETE FROM public.finance_dashboard_expense_daily;
DELETE FROM public.finance_dashboard_coverage;
