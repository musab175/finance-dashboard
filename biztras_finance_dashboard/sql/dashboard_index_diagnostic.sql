-- Finance Dashboard - index diagnostic (read-only, safe to run anytime)
--
-- Purpose: show every existing index on account_move_line and account_move,
-- the two tables get_dashboard_data() reads from, so we know what Postgres
-- already has covered before adding anything.
--
-- How to use: run this against your real database (psql, DBeaver, pgAdmin,
-- whatever you have) and share the output. Nothing here writes anything.

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
