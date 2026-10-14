-- SECTION 4 TEST AID: READ-ONLY SNAPSHOT AROUND THE ROLLBACK-ONLY TESTS.
-- 2026-10-13.
--
-- Taken before L-A, after L-A and after L-B. Snapshots of an unchanged
-- database are identical line for line, except the lines starting with
-- seq_layer: - the five reporting tables' id sequences, which an INSERT
-- advances even inside a transaction that is rolled back.
--
-- RUN, read-only, through the local socket, with DateStyle fixed so every
-- snapshot prints dates the same way:
--   sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on -c DateStyle=ISO'
--     psql -X -At -F '|' -v ON_ERROR_STOP=1 -h /var/run/postgresql -p 5432
--     -d gftuae -f 12c_test_snapshot.sql > S0.txt
-- COMPARE:
--   diff <(grep -v '^seq_layer:' S0.txt) <(grep -v '^seq_layer:' S1.txt) && echo IDENTICAL
--
-- LINES (key|value)
--   precondition:other_backends  client connections to this database other than
--                                this one. MUST BE 0. A connection publishes its
--                                last statistics as it closes, so a snapshot
--                                taken while odoo shell's connections are still
--                                closing could miss a write. If it is not 0,
--                                wait a few seconds and take the snapshot again.
--   precondition:...             database, read-only guard, DateStyle, cluster
--                                start time (a restart between snapshots shows)
--   layer:<table>:...            for each of the five reporting tables: rows,
--                                the sum of every amount column, and a content
--                                hash - the sum of a 64-bit hash of each row's
--                                full text, id included. Coverage also: its
--                                dates, refresh time and ok-flag count.
--   outside:<schema.table>       inserts,updates,deletes PostgreSQL has counted
--                                for every OTHER table. Rolled-back writes are
--                                counted too, so an unchanged line means the
--                                test wrote nothing to that table, committed or
--                                not.
--   seq:<schema.sequence>        last value of every other sequence
--   seq_layer:<schema.sequence>  the five reporting tables' id sequences:
--                                expected to advance, nothing else
--
-- NOT COVERED, by design: planner statistics (pg_class.reltuples / relpages),
-- which the ANALYZE statements in 04 update in place even when the refresh is
-- rolled back; dead rows and WAL. None of them is reporting or ledger data.
--
-- The SQL below is one read-only statement.
WITH d AS (
  SELECT count(*) AS n,
         sum(sales) AS sales, sum(cogs) AS cogs, sum(opex) AS opex,
         sum(other_income) AS other_income, sum(depreciation) AS depreciation,
         sum(sales_ic) AS sales_ic, sum(cogs_ic) AS cogs_ic,
         sum(cash_bank_delta) AS cash_bank_delta, sum(ar_delta) AS ar_delta,
         sum(ap_delta) AS ap_delta, sum(ar_ic_delta) AS ar_ic_delta,
         sum(ap_ic_delta) AS ap_ic_delta,
         sum(other_current_assets_delta) AS oca_delta,
         sum(other_current_liabilities_delta) AS ocl_delta,
         sum(other_current_assets_ic_delta) AS oca_ic_delta,
         sum(other_current_liabilities_ic_delta) AS ocl_ic_delta,
         sum(hashtextextended(t::text, 0)::numeric) AS h
    FROM finance_dashboard_daily t
), a AS (
  SELECT count(*) AS n, sum(ar_amount) AS ar, sum(ap_amount) AS ap,
         count(*) FILTER (WHERE is_intercompany) AS ic_rows,
         sum(hashtextextended(t::text, 0)::numeric) AS h
    FROM finance_dashboard_arap_daily t
), g AS (
  SELECT count(*) AS n, sum(ar_amount) AS ar, sum(ap_amount) AS ap,
         sum(hashtextextended(t::text, 0)::numeric) AS h
    FROM finance_dashboard_aging_daily t
), e AS (
  SELECT count(*) AS n, sum(amount) AS amount,
         sum(hashtextextended(t::text, 0)::numeric) AS h
    FROM finance_dashboard_expense_daily t
), c AS (
  SELECT count(*) AS n, min(covered_from) AS covered_from,
         max(covered_to) AS covered_to,
         COALESCE(to_char(max(last_refresh_at), 'YYYY-MM-DD HH24:MI:SS.US'), '') AS stamp,
         count(*) FILTER (WHERE last_refresh_ok) AS ok_rows,
         sum(hashtextextended(t::text, 0)::numeric) AS h
    FROM finance_dashboard_coverage t
)
SELECT k, v FROM (
  SELECT 0 AS o, 'precondition:other_backends' AS k,
         (SELECT count(*) FROM pg_stat_activity
           WHERE datname = current_database()
             AND pid <> pg_backend_pid()
             AND backend_type = 'client backend')::text AS v
  UNION ALL SELECT 0, 'precondition:database', current_database()
  UNION ALL SELECT 0, 'precondition:read_only', current_setting('transaction_read_only')
  UNION ALL SELECT 0, 'precondition:datestyle', current_setting('DateStyle')
  UNION ALL SELECT 0, 'precondition:postmaster_start',
                   to_char(pg_postmaster_start_time() AT TIME ZONE 'UTC',
                           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
  UNION ALL
  SELECT 1, x.k, x.v FROM d, LATERAL (VALUES
      ('layer:daily:rows', d.n::text),
      ('layer:daily:sum:sales', d.sales::text),
      ('layer:daily:sum:cogs', d.cogs::text),
      ('layer:daily:sum:opex', d.opex::text),
      ('layer:daily:sum:other_income', d.other_income::text),
      ('layer:daily:sum:depreciation', d.depreciation::text),
      ('layer:daily:sum:sales_ic', d.sales_ic::text),
      ('layer:daily:sum:cogs_ic', d.cogs_ic::text),
      ('layer:daily:sum:cash_bank_delta', d.cash_bank_delta::text),
      ('layer:daily:sum:ar_delta', d.ar_delta::text),
      ('layer:daily:sum:ap_delta', d.ap_delta::text),
      ('layer:daily:sum:ar_ic_delta', d.ar_ic_delta::text),
      ('layer:daily:sum:ap_ic_delta', d.ap_ic_delta::text),
      ('layer:daily:sum:other_current_assets_delta', d.oca_delta::text),
      ('layer:daily:sum:other_current_liabilities_delta', d.ocl_delta::text),
      ('layer:daily:sum:other_current_assets_ic_delta', d.oca_ic_delta::text),
      ('layer:daily:sum:other_current_liabilities_ic_delta', d.ocl_ic_delta::text),
      ('layer:daily:content', d.h::text)) AS x(k, v)
  UNION ALL
  SELECT 1, x.k, x.v FROM a, LATERAL (VALUES
      ('layer:arap_daily:rows', a.n::text),
      ('layer:arap_daily:rows_intercompany', a.ic_rows::text),
      ('layer:arap_daily:sum:ar_amount', a.ar::text),
      ('layer:arap_daily:sum:ap_amount', a.ap::text),
      ('layer:arap_daily:content', a.h::text)) AS x(k, v)
  UNION ALL
  SELECT 1, x.k, x.v FROM g, LATERAL (VALUES
      ('layer:aging_daily:rows', g.n::text),
      ('layer:aging_daily:sum:ar_amount', g.ar::text),
      ('layer:aging_daily:sum:ap_amount', g.ap::text),
      ('layer:aging_daily:content', g.h::text)) AS x(k, v)
  UNION ALL
  SELECT 1, x.k, x.v FROM e, LATERAL (VALUES
      ('layer:expense_daily:rows', e.n::text),
      ('layer:expense_daily:sum:amount', e.amount::text),
      ('layer:expense_daily:content', e.h::text)) AS x(k, v)
  UNION ALL
  SELECT 1, x.k, x.v FROM c, LATERAL (VALUES
      ('layer:coverage:rows', c.n::text),
      ('layer:coverage:covered_from', c.covered_from::text),
      ('layer:coverage:covered_to', c.covered_to::text),
      ('layer:coverage:last_refresh_at', c.stamp),
      ('layer:coverage:ok_rows', c.ok_rows::text),
      ('layer:coverage:content', c.h::text)) AS x(k, v)
  UNION ALL
  SELECT 2, 'outside:' || schemaname || '.' || relname,
         n_tup_ins::text || ',' || n_tup_upd::text || ',' || n_tup_del::text
    FROM pg_stat_user_tables
   WHERE NOT (schemaname = 'public'
              AND relname IN ('finance_dashboard_daily', 'finance_dashboard_arap_daily',
                              'finance_dashboard_aging_daily',
                              'finance_dashboard_expense_daily',
                              'finance_dashboard_coverage'))
  UNION ALL
  SELECT 3, CASE WHEN schemaname = 'public'
                  AND sequencename IN ('finance_dashboard_daily_id_seq',
                                       'finance_dashboard_arap_daily_id_seq',
                                       'finance_dashboard_aging_daily_id_seq',
                                       'finance_dashboard_expense_daily_id_seq',
                                       'finance_dashboard_coverage_id_seq')
                 THEN 'seq_layer:' ELSE 'seq:' END || schemaname || '.' || sequencename,
         COALESCE(last_value::text, 'null')
    FROM pg_sequences
) AS snapshot
ORDER BY o, k;
