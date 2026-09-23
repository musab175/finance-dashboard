-- ONE LOGICAL REFRESH.
--
-- Run this file with:  psql -v ON_ERROR_STOP=1 --single-transaction -f 05_refresh_all.sql
--
-- All three backfills plus the coverage stamp execute inside a single
-- transaction, so the reporting layer only ever moves from one complete
-- vintage to the next. Previously each script had its own transaction, which
-- allowed states like "daily = new, AR/AP = old, expense = new, aging = old".
--
-- Failure behaviour: ON_ERROR_STOP aborts at the first error and the enclosing
-- transaction rolls back in full. Every table returns to the previous vintage,
-- including finance_dashboard_coverage, so the dashboard's advertised
-- last_refresh_at never claims a refresh that did not complete.
--
-- Reader behaviour: under MVCC readers keep seeing the pre-refresh snapshot for
-- the whole duration and switch atomically at COMMIT. No statement here takes
-- an ACCESS EXCLUSIVE lock, so dashboard queries are never blocked and no table
-- is ever absent.
--
-- NOTE: VACUUM is deliberately NOT here. "VACUUM cannot run inside a
-- transaction block" (verified against this server), so the shell driver runs
-- VACUUM (ANALYZE) on a separate connection after this transaction commits.
-- Plain ANALYZE IS valid inside a transaction and stays at the end of 04.
--
-- 01_create_summary.sql is intentionally absent: it DROPs and recreates the
-- tables and is a one-time provisioning step, never part of a refresh.

\echo '>>> 02_backfill_daily.sql (flow + snapshot deltas, upsert on (company_id, date))'
\i 02_backfill_daily.sql

\echo '>>> 03_backfill_arap.sql (AR/AP detail, incremental merge: update changed / insert new / delete removed)'
\i 03_backfill_arap.sql

\echo '>>> 04_backfill_expense_and_derived.sql (expense upsert, aging replace, coverage stamp)'
\i 04_backfill_expense_and_derived.sql

\echo '>>> all stages staged; COMMIT is issued by psql --single-transaction'
