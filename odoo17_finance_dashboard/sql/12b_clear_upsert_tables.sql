-- SECTION 4: EMPTY THE THREE UPDATE-IN-PLACE TABLES BEFORE A REFRESH. 2026-10-13.
--
-- RUN ONLY BY 12a_refresh_transaction.py, inside its single refresh transaction,
-- after the account-type guard and before refresh_full(). Never on its own: run
-- outside that transaction it would leave the dashboard with no data.
--
-- WHY: these three tables are filled by upserts - finance_dashboard_daily by
-- 02_backfill_daily.sql, finance_dashboard_expense_daily and
-- finance_dashboard_coverage by 04_backfill_expense_and_derived.sql. An upsert
-- only visits the keys its SELECT produces now, so a key whose ledger lines were
-- unposted, redated or reclassified keeps its old values for ever (02 says so at
-- lines 80-83). With the full-range gate such a row fails 06b or 06c on every
-- refresh, and the layer could not be refreshed again without manual repair.
-- Emptying the three tables first makes a refresh over existing data produce
-- exactly what a build into empty tables produces.
--   finance_dashboard_arap_daily  - not here: 03 already deletes vanished keys.
--   finance_dashboard_aging_daily - not here: 04 already empties it first.
--
-- DELETE, NOT TRUNCATE: DELETE takes row locks only. Other sessions keep seeing
-- the previous rows until COMMIT, and a ROLLBACK leaves them exactly as they
-- were. TRUNCATE would take an ACCESS EXCLUSIVE lock until the end of the
-- transaction.
--
-- Executed through Odoo's cursor without parameters: no percent sign anywhere
-- in this file, comments included (see 06b_validate_live_inline.sql).
--
-- Approved 2026-10-13: Section 4, Decision 1.
DELETE FROM finance_dashboard_daily;
DELETE FROM finance_dashboard_expense_daily;
DELETE FROM finance_dashboard_coverage;
