-- SCHEMA PARITY GATE. 2026-10-08.
--
-- The reporting layer can now be provisioned TWO ways:
--   (a) psql -f 01_create_summary.sql        - works with no Odoo registry
--   (b) odoo -i odoo17_finance_dashboard     - ORM models in models/finance_dashboard_layer.py
--
-- Both must produce the SAME schema or the two paths silently diverge. This
-- script asserts the schema is correct whichever way it was built. Run it after
-- EITHER path; the output must be identical.
--
-- KNOWN AND ACCEPTED DIFFERENCE: the ORM path adds an `id` serial primary key,
-- because every Odoo model is forced to have one. The composite primary keys
-- from 01 become UNIQUE constraints instead. This is functionally equivalent for
-- our purposes - ON CONFLICT requires a unique INDEX, which a UNIQUE constraint
-- provides - so 02's upsert works under both. The check below therefore tests
-- for a unique index on the grain columns, not for a PRIMARY KEY specifically.

\echo '=== 1. all five reporting tables present ==='
WITH required(t) AS (VALUES
    ('finance_dashboard_daily'),('finance_dashboard_arap_daily'),
    ('finance_dashboard_aging_daily'),('finance_dashboard_expense_daily'),
    ('finance_dashboard_coverage'))
SELECT r.t AS table_name,
       CASE WHEN to_regclass('public.'||r.t) IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS status,
       COALESCE((SELECT tableowner FROM pg_tables
                  WHERE schemaname='public' AND tablename=r.t),'-') AS owner
  FROM required r ORDER BY 1;

\echo '=== 2. money columns must be numeric(18,2) - NOT unconstrained numeric ==='
-- fields.Float(digits=...) yields unconstrained numeric. 02 inserts a bare SUM()
-- and relies on the column type to round to 2dp, so an unconstrained column
-- would store more precision than the SQL path. init() ALTERs them; this proves it.
WITH expected(tbl, col) AS (VALUES
    ('finance_dashboard_daily','sales'),('finance_dashboard_daily','cogs'),
    ('finance_dashboard_daily','opex'),('finance_dashboard_daily','other_income'),
    ('finance_dashboard_daily','depreciation'),('finance_dashboard_daily','sales_ic'),
    ('finance_dashboard_daily','cogs_ic'),('finance_dashboard_daily','cash_bank_delta'),
    ('finance_dashboard_daily','ar_delta'),('finance_dashboard_daily','ap_delta'),
    ('finance_dashboard_daily','ar_ic_delta'),('finance_dashboard_daily','ap_ic_delta'),
    ('finance_dashboard_daily','other_current_assets_delta'),
    ('finance_dashboard_daily','other_current_liabilities_delta'),
    ('finance_dashboard_daily','other_current_assets_ic_delta'),
    ('finance_dashboard_daily','other_current_liabilities_ic_delta'),
    ('finance_dashboard_arap_daily','ar_amount'),
    ('finance_dashboard_arap_daily','ap_amount'),
    ('finance_dashboard_expense_daily','amount'))
SELECT e.tbl, e.col, c.data_type, c.numeric_precision, c.numeric_scale,
       CASE WHEN c.column_name IS NULL THEN 'FAIL: column missing'
            WHEN (c.numeric_precision, c.numeric_scale) = (18,2) THEN 'PASS'
            ELSE 'FAIL: expected numeric(18,2)' END AS status
  FROM expected e
  LEFT JOIN information_schema.columns c
         ON c.table_schema='public' AND c.table_name=e.tbl AND c.column_name=e.col
 WHERE c.column_name IS NULL OR (c.numeric_precision, c.numeric_scale) IS DISTINCT FROM (18,2)
 ORDER BY 1,2;
\echo '(no rows above = every money column is numeric(18,2))'

\echo '=== 3. aging amounts stay UNCONSTRAINED numeric (deliberate) ==='
SELECT column_name, data_type, numeric_precision,
       CASE WHEN numeric_precision IS NULL THEN 'PASS' ELSE 'FAIL: should be unconstrained' END AS status
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='finance_dashboard_aging_daily'
   AND column_name IN ('ar_amount','ap_amount') ORDER BY 1;

\echo '=== 4. required indexes / unique constraints ==='
WITH required(idx, tbl, why) AS (VALUES
    ('finance_dashboard_arap_uk','finance_dashboard_arap_daily','grain key for 03 merge (COALESCE-normalised)'),
    ('finance_dashboard_arap_daily_idx','finance_dashboard_arap_daily','read path'),
    ('finance_dashboard_aging_idx','finance_dashboard_aging_daily','covering index, INCLUDE'),
    ('finance_dashboard_arap_partner_idx','finance_dashboard_arap_daily','created by 04, top-5 partners'))
SELECT r.idx, r.why,
       CASE WHEN i.indexname IS NULL THEN 'MISSING' ELSE 'PASS' END AS status
  FROM required r LEFT JOIN pg_indexes i
    ON i.schemaname='public' AND i.indexname=r.idx
 ORDER BY 1;

\echo '=== 5. a unique index must cover each upsert target ==='
-- 02 uses ON CONFLICT (company_id, date); 04 uses (company_id, date, account_id)
-- and (company_id). Each needs a unique index, whether from a PK or a constraint.
SELECT tablename, indexname, indexdef
  FROM pg_indexes
 WHERE schemaname='public'
   AND tablename IN ('finance_dashboard_daily','finance_dashboard_expense_daily',
                     'finance_dashboard_coverage')
   AND indexdef LIKE 'CREATE UNIQUE%'
 ORDER BY 1,2;
\echo '(expect one UNIQUE index per table on its grain columns)'

\echo '=== 6. which path built this? (informational) ==='
SELECT CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                          WHERE table_schema='public'
                            AND table_name='finance_dashboard_daily'
                            AND column_name='id')
            THEN 'ORM path (odoo -i) - id column present'
            ELSE 'SQL path (01_create_summary.sql) - no id column'
       END AS provisioned_by;
