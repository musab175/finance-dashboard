-- Finance Dashboard - index diagnostic (read-only, safe to run anytime)
--
-- Purpose: show every existing index on account_move_line and account_move,
-- the two tables get_dashboard_data() reads from, so we know what Postgres
-- already has covered before adding anything.
--
-- How to use: run this against your real database (psql, DBeaver, pgAdmin,
-- whatever you have) and share the output. Nothing here writes anything.
--
-- This was run for real against the gftuae production database on
-- 2026-09-11 as part of diagnosing the Finance Dashboard's initial-load
-- time (338,705 account_move_line rows for Gulf Fruits Trade Company
-- LLC). See PERFORMANCE_CHANGES.md, "Finance Dashboard Initial-Load
-- Optimization" for the findings and what was applied as a result
-- (dashboard_indexes.sql). Use the "index usage since applying the fix"
-- query at the bottom of this file if load ever becomes slow again -
-- it's the fastest way to check whether the applied indexes are still
-- actually being used by the query planner.

SELECT
    t.relname AS table_name,
    i.relname AS index_name,
    array_to_string(array_agg(a.attname ORDER BY x.n), ', ') AS columns,
    ix.indisunique AS is_unique,
    pg_get_indexdef(ix.indexrelid) AS full_definition
FROM pg_index ix
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS x(attnum, n) ON true
JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = x.attnum
WHERE n.nspname = 'public'
  AND t.relname IN ('account_move_line', 'account_move')
GROUP BY t.relname, i.relname, ix.indisunique, ix.indexrelid
ORDER BY t.relname, i.relname;

-- Also useful: current row counts, so we know whether these queries are
-- actually operating at a scale where indexing matters yet.
SELECT 'account_move_line' AS table_name, count(*) AS row_count FROM account_move_line
UNION ALL
SELECT 'account_move', count(*) FROM account_move;

-- Index usage since applying the fix - run this any time the dashboard
-- feels slow again. idx_scan should keep climbing on both dashboard
-- indexes as the app is used. If either sits at 0 for a while despite
-- normal usage, the planner has stopped choosing it (data volume/shape
-- changed enough to shift the plan) and this whole investigation should
-- be redone rather than assumed still valid.
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE relname = 'account_move_line'
  AND indexrelname LIKE 'idx_aml_dash%'
ORDER BY indexrelname;
