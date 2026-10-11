-- SECTION 2 ASSESSMENT, PART B: FINGERPRINT, MODULE AND REPORTING-LAYER FACTS.
-- 2026-10-11.
--
-- READ-ONLY, ONE STATEMENT. Run by 10_assess.sh only after 10a has confirmed the
-- connection is the local socket to the Odoo database gftuae. This file COLLECTS
-- facts and decides nothing. The verdict is made in 10_assess.sh, where it can be
-- tested with made-up facts.
--
-- WHY query_to_xml: after the daily replacement the reporting tables do not exist,
-- and a plain SELECT from a missing table fails the whole statement. query_to_xml
-- runs a query passed as text, so a row count is attempted only inside CASE, once
-- to_regclass has shown the table exists. It only reads.
--
-- MIRRORS 08_verify_schema_parity.sql in machine-readable form. 08 is unchanged and
-- stays the human-readable report. Two checks are deliberately stricter:
--   * aging amounts must be type numeric AND unconstrained. 08 checks only that the
--     precision is NULL, which a text column would also pass.
--   * the unique grain index is matched by its definition, not its name, because
--     Odoo names constraint indexes itself and truncates names past 63 characters.
-- finance_dashboard_arap_partner_idx is created by 04 during a refresh, so it is
-- reported (partner_idx), not treated as part of the provisioned schema.
--
-- FINGERPRINT (approved 2026-10-01, revised 14:03 UTC; extended 2026-10-11):
--   uuid               wrong-database detector - STOP on mismatch
--   postmaster_start   cluster restart marker - a replacement restarts the cluster
--   max_aml_id         content watermark - new ledger lines
--   aml_n_tup_ins/upd/del  PostgreSQL's running insert, update and delete counts
--                      for account_move_line (pg_stat_user_tables). They catch an
--                      edit to an EXISTING line, e.g. posting a draft entry, which
--                      creates no new id. Change INDICATORS, not an audit trail:
--                      see the limits in 10_assess.sh.
--   track_counts       must be on, or those counters never move
--   pg_database_oid    audit only - proven not to change on replacement
--   system_identifier  audit only - physical copies share it
--   stats_reset        audit only - when this database's statistics were last reset
--
-- OUTPUT: key|value rows (psql -At -F '|').

WITH reporting(t) AS (VALUES
    ('finance_dashboard_daily'), ('finance_dashboard_arap_daily'),
    ('finance_dashboard_aging_daily'), ('finance_dashboard_expense_daily'),
    ('finance_dashboard_coverage')
), layer AS (
    SELECT t,
           to_regclass('public.' || t) IS NOT NULL AS present,
           CASE WHEN to_regclass('public.' || t) IS NOT NULL THEN
                (xpath('/row/n/text()',
                       query_to_xml('SELECT count(*) AS n FROM public.' || quote_ident(t),
                                    false, true, '')))[1]::text
           END AS n_rows
      FROM reporting
), money(tbl, col) AS (VALUES
    ('finance_dashboard_daily', 'sales'),
    ('finance_dashboard_daily', 'cogs'),
    ('finance_dashboard_daily', 'opex'),
    ('finance_dashboard_daily', 'other_income'),
    ('finance_dashboard_daily', 'depreciation'),
    ('finance_dashboard_daily', 'sales_ic'),
    ('finance_dashboard_daily', 'cogs_ic'),
    ('finance_dashboard_daily', 'cash_bank_delta'),
    ('finance_dashboard_daily', 'ar_delta'),
    ('finance_dashboard_daily', 'ap_delta'),
    ('finance_dashboard_daily', 'ar_ic_delta'),
    ('finance_dashboard_daily', 'ap_ic_delta'),
    ('finance_dashboard_daily', 'other_current_assets_delta'),
    ('finance_dashboard_daily', 'other_current_liabilities_delta'),
    ('finance_dashboard_daily', 'other_current_assets_ic_delta'),
    ('finance_dashboard_daily', 'other_current_liabilities_ic_delta'),
    ('finance_dashboard_arap_daily', 'ar_amount'),
    ('finance_dashboard_arap_daily', 'ap_amount'),
    ('finance_dashboard_expense_daily', 'amount')
), money_bad AS (
    SELECT count(*) AS n
      FROM money m
      LEFT JOIN information_schema.columns c
             ON c.table_schema = 'public' AND c.table_name = m.tbl
            AND c.column_name = m.col
     WHERE c.column_name IS NULL
        OR c.data_type <> 'numeric'
        OR (c.numeric_precision, c.numeric_scale) IS DISTINCT FROM (18, 2)
), aging_bad AS (
    SELECT count(*) AS n
      FROM (VALUES ('ar_amount'), ('ap_amount')) AS a(col)
      LEFT JOIN information_schema.columns c
             ON c.table_schema = 'public'
            AND c.table_name = 'finance_dashboard_aging_daily'
            AND c.column_name = a.col
     WHERE c.column_name IS NULL
        OR c.data_type <> 'numeric'
        OR c.numeric_precision IS NOT NULL
), required_index(name) AS (VALUES
    ('finance_dashboard_aging_idx'),
    ('finance_dashboard_arap_daily_idx'),
    ('finance_dashboard_arap_uk')
), grain(tbl, cols) AS (VALUES
    ('finance_dashboard_coverage',      'company_id'),
    ('finance_dashboard_daily',         'company_id, date'),
    ('finance_dashboard_expense_daily', 'company_id, date, account_id')
)
SELECT key, value FROM (
              SELECT 1 AS o, 'uuid' AS key,
                     (SELECT value FROM ir_config_parameter
                       WHERE key = 'database.uuid')::text AS value
    UNION ALL SELECT 2, 'postmaster_start',
                     to_char(pg_postmaster_start_time() AT TIME ZONE 'UTC',
                             'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    UNION ALL SELECT 3, 'max_aml_id', (SELECT max(id) FROM account_move_line)::text
    UNION ALL SELECT 3, 'aml_n_tup_ins',
                     (SELECT n_tup_ins FROM pg_stat_user_tables
                       WHERE relid = 'public.account_move_line'::regclass)::text
    UNION ALL SELECT 3, 'aml_n_tup_upd',
                     (SELECT n_tup_upd FROM pg_stat_user_tables
                       WHERE relid = 'public.account_move_line'::regclass)::text
    UNION ALL SELECT 3, 'aml_n_tup_del',
                     (SELECT n_tup_del FROM pg_stat_user_tables
                       WHERE relid = 'public.account_move_line'::regclass)::text
    UNION ALL SELECT 3, 'track_counts', current_setting('track_counts')
    UNION ALL SELECT 4, 'pg_database_oid',
                     (SELECT oid FROM pg_database WHERE datname = current_database())::text
    UNION ALL SELECT 5, 'system_identifier',
                     (SELECT system_identifier FROM pg_control_system())::text
    UNION ALL SELECT 5, 'stats_reset',
                     COALESCE((SELECT stats_reset FROM pg_stat_database
                                WHERE datname = current_database())::text, '')
    UNION ALL SELECT 6, 'module_state',
                     COALESCE((SELECT state FROM ir_module_module
                                WHERE name = 'odoo17_finance_dashboard'), 'absent')::text
    UNION ALL SELECT 7, 'pending_modules',
                     COALESCE((SELECT string_agg(name || ':' || state, ',' ORDER BY name)
                                 FROM ir_module_module
                                WHERE state IN ('to install', 'to upgrade', 'to remove')), '')::text
    UNION ALL SELECT 10, 'present:' || t, present::text FROM layer
    UNION ALL SELECT 11, 'rows:' || t, COALESCE(n_rows, '') FROM layer
    UNION ALL SELECT 20, 'provisioned_by',
                     CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                                        WHERE table_schema = 'public'
                                          AND table_name = 'finance_dashboard_daily'
                                          AND column_name = 'id') THEN 'orm'
                          WHEN to_regclass('public.finance_dashboard_daily') IS NOT NULL THEN 'sql'
                          ELSE 'none' END
    UNION ALL SELECT 21, 'schema_money_bad', (SELECT n FROM money_bad)::text
    UNION ALL SELECT 22, 'schema_aging_bad', (SELECT n FROM aging_bad)::text
    UNION ALL SELECT 23, 'schema_index_missing',
                     COALESCE((SELECT string_agg(r.name, ',' ORDER BY r.name)
                                 FROM required_index r
                                WHERE NOT EXISTS (SELECT 1 FROM pg_indexes p
                                                   WHERE p.schemaname = 'public'
                                                     AND p.indexname = r.name)), '')
    UNION ALL SELECT 24, 'schema_grain_missing',
                     COALESCE((SELECT string_agg(g.tbl, ',' ORDER BY g.tbl)
                                 FROM grain g
                                WHERE NOT EXISTS (
                                      SELECT 1 FROM pg_indexes p
                                       WHERE p.schemaname = 'public'
                                         AND p.tablename = g.tbl
                                         AND starts_with(p.indexdef, 'CREATE UNIQUE INDEX ')
                                         AND right(p.indexdef,
                                                   length(' USING btree (' || g.cols || ')'))
                                             = ' USING btree (' || g.cols || ')')), '')
    UNION ALL SELECT 25, 'partner_idx',
                     (EXISTS (SELECT 1 FROM pg_indexes
                               WHERE schemaname = 'public'
                                 AND indexname = 'finance_dashboard_arap_partner_idx'))::text
    UNION ALL SELECT 26, 'coverage_last_refresh',
                     COALESCE(CASE WHEN to_regclass('public.finance_dashboard_coverage') IS NOT NULL THEN
                              (xpath('/row/v/text()',
                                     query_to_xml('SELECT max(last_refresh_at)::text AS v'
                                                  || ' FROM public.finance_dashboard_coverage',
                                                  false, true, '')))[1]::text
                              END, '')
) AS f
ORDER BY o, key;
