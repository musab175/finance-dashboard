-- BOOTSTRAP GATE: does the COMPLETE reporting layer exist? 2026-10-01.
--
-- WHY THIS IS NOT A WILDCARD COUNT:
--   `tablename LIKE 'finance_dashboard%'` is UNSAFE. On 2026-10-01 the server
--   showed SEVEN such tables, not five. Two of them —
--     finance_dashboard_category_sales_daily
--     finance_dashboard_category_sales_coverage
--   are created by Odoo's ORM when the MODULE installs (models
--   finance.dashboard.category.sales.daily / .coverage in
--   models/finance_dashboard_report.py). They are NOT reporting-layer tables and
--   01_create_summary.sql neither creates nor touches them.
--
--   So a wildcard count returns 2 on a database where the module is installed and
--   the reporting layer has NEVER been built — a FALSE POSITIVE for precisely the
--   condition the bootstrap exists to detect.
--
-- THE FIVE, read from 01_create_summary.sql's own CREATE TABLE statements:
--   finance_dashboard_daily, finance_dashboard_arap_daily,
--   finance_dashboard_aging_daily, finance_dashboard_expense_daily,
--   finance_dashboard_coverage
--
-- THREE OUTCOMES, no silent middle ground:
--   PRESENT     all five exist           -> skip the build
--   NOT PRESENT none of the five exist   -> build
--   INCOMPLETE  some exist, some do not  -> FAIL. Never treated as valid.

WITH required(t) AS (VALUES
    ('finance_dashboard_daily'),
    ('finance_dashboard_arap_daily'),
    ('finance_dashboard_aging_daily'),
    ('finance_dashboard_expense_daily'),
    ('finance_dashboard_coverage')
), found AS (
    SELECT r.t,
           (to_regclass('public.'||r.t) IS NOT NULL) AS present,
           (SELECT tableowner FROM pg_tables
             WHERE schemaname='public' AND tablename=r.t) AS owner
      FROM required r
), tally AS (
    SELECT count(*) FILTER (WHERE present)     AS n_present,
           count(*)                            AS n_required
      FROM found
)
SELECT CASE WHEN n_present = n_required THEN 'REPORTING LAYER PRESENT'
            WHEN n_present = 0          THEN 'REPORTING LAYER NOT PRESENT'
            ELSE 'FAIL: INCOMPLETE REPORTING LAYER'
       END                                                  AS detection_result,
       n_present || ' of ' || n_required || ' required tables' AS detail
  FROM tally;

-- Per-table evidence, including owner. Ownership matters: if a rebuild is run as
-- `postgres` the tables are recreated owned by postgres and Odoo gets permission
-- denied. Expected owner on this deployment: gftuae.
WITH required(t) AS (VALUES
    ('finance_dashboard_daily'),('finance_dashboard_arap_daily'),
    ('finance_dashboard_aging_daily'),('finance_dashboard_expense_daily'),
    ('finance_dashboard_coverage'))
SELECT r.t AS required_table,
       (to_regclass('public.'||r.t) IS NOT NULL) AS present,
       COALESCE((SELECT tableowner FROM pg_tables
                  WHERE schemaname='public' AND tablename=r.t), '-') AS owner
  FROM required r ORDER BY 1;

-- Informational ONLY: ORM-managed tables in the same namespace. Their presence or
-- absence says nothing about the reporting layer and must never gate anything.
SELECT tablename AS orm_managed_not_reporting_layer, tableowner
  FROM pg_tables
 WHERE schemaname='public'
   AND tablename IN ('finance_dashboard_category_sales_daily',
                     'finance_dashboard_category_sales_coverage')
 ORDER BY 1;
