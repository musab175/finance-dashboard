-- IN-TRANSACTION VALIDATION GATE. Additive companion to 06_validate_live.sql.
--
-- PURPOSE: lets the orchestrator validate the reporting layer INSIDE the same
-- transaction as refresh_full(), BEFORE commit. A failure then rolls back the
-- refresh and the previous reporting data survives intact. 06_validate_live.sql
-- cannot do this: it uses psql meta-commands, which Odoo's cursor rejects.
--
-- 06_validate_live.sql IS UNCHANGED and remains the tool for manual validation.
--
-- WHAT DIFFERS FROM 06_validate_live.sql - nothing else:
--   1. psql meta-commands (the three if/set lines) removed.
--   2. The date window is written as literal dates in the four WHERE clauses
--      and covers the FULL RANGE, where 06 takes psql variables that default to
--      1-18 March 2026. See WINDOW and PLANNER.
--   3. The unused `ic` CTE is removed. It has been dead code since commit
--      2bc1461 replaced its only reference with an IN (subquery) predicate.
-- The sixteen measure expressions are BYTE-IDENTICAL to 06_validate_live.sql.
-- This file was produced by mechanical transformation, not retyped.
--
-- PORTABILITY: pure SQL, a single statement. Runs unchanged through psql AND
-- through Odoo's env.cr.execute(). Test it with psql first.
--
-- DO NOT ADD A PERCENT SIGN ANYWHERE IN THIS FILE, COMMENTS INCLUDED. If a caller
-- ever passes parameters to cr.execute(), psycopg2 interpolates every percent
-- sign in the string, comments and all. This file deliberately takes no
-- parameters so that hazard cannot arise. Keep it that way.
--
-- NULL IS A FAILURE, DELIBERATELY. If a reporting table is empty, its SUM is
-- NULL, the difference is NULL, and the status falls through to FAIL. An empty
-- build must never pass the gate. Do not add COALESCE to the reporting side.
--
-- WINDOW: FULL RANGE - every posted line on every date (2026-10-11).
--   * 06's March default leaves every date after 2026-03-18 ungated, and that
--     is where recent edits land.
--   * 02 and 04 are upserts and never remove a key that has left the ledger
--     (02 says so at lines 80-83). A full-range gate sees such a stale row
--     wherever it is dated. It cannot see two stale rows that cancel exactly.
--     Removing stale rows is the refresh's job, not this gate's.
--   * 0001-01-01 and 9999-12-31 are Python's date.min and date.max, the bounds
--     of every date Odoo can read or write, so no ledger line falls outside.
-- The unchanged 06_validate_live.sql reproduces this file's result with:
--   psql -v as_of=9999-12-31 -v df=0001-01-01 -v dt=9999-12-31 -f 06_validate_live.sql
--
-- PLANNER - KEEP THE DATES LITERAL. Do not move them into a CTE or a
-- subquery. PostgreSQL picks the plan before it evaluates such values, and then
-- assumes a two-sided date range keeps 0.5 percent of the rows. On 2026-10-11
-- that planned the flow scan as an Index Scan over every ledger line (planned
-- rows=151568 against about 30 million real), and the run was cancelled
-- unfinished. With literal dates the planner sees that every row matches and
-- reads the table sequentially, exactly as it does for 06.
--
-- ORCHESTRATOR USE: run after refresh_full() and BEFORE commit, in the same
-- transaction, together with 06c_validate_cross_table.sql. Odoo's cursor is
-- REPEATABLE READ, so the refresh and this gate read one snapshot of the
-- ledger. Any row whose status is not PASS means rollback.

WITH src_snap AS (
  SELECT
    SUM(CASE WHEN aa.account_type='asset_cash' THEN aml.balance ELSE 0 END)                   AS cash,
    SUM(CASE WHEN aa.account_type='asset_receivable' AND NOT aa.non_trade
             THEN aml.balance ELSE 0 END)                                                     AS ar,
    SUM(CASE WHEN aa.account_type='asset_receivable' AND NOT aa.non_trade
                  AND aml.journal_id IN (SELECT account_journal_id FROM account_journal_account_journal_group_rel) THEN aml.balance ELSE 0 END)    AS ar_ic,
    SUM(CASE WHEN aa.account_type='liability_payable' AND NOT aa.non_trade
             THEN aml.balance ELSE 0 END)                                                     AS ap,
    SUM(CASE WHEN aa.account_type='liability_payable' AND NOT aa.non_trade
                  AND aml.journal_id IN (SELECT account_journal_id FROM account_journal_account_journal_group_rel) THEN aml.balance ELSE 0 END)    AS ap_ic,
    SUM(CASE WHEN aa.account_type='asset_current'
                  OR (aa.account_type='asset_receivable' AND aa.non_trade)
             THEN aml.balance ELSE 0 END)                                                     AS oca,
    SUM(CASE WHEN (aa.account_type='asset_current'
                   OR (aa.account_type='asset_receivable' AND aa.non_trade))
                  AND aml.journal_id IN (SELECT account_journal_id FROM account_journal_account_journal_group_rel) THEN aml.balance ELSE 0 END)    AS oca_ic,
    SUM(CASE WHEN aa.account_type IN ('liability_current','liability_credit_card')
                  OR (aa.account_type='liability_payable' AND aa.non_trade)
             THEN aml.balance ELSE 0 END)                                                     AS ocl,
    SUM(CASE WHEN (aa.account_type IN ('liability_current','liability_credit_card')
                   OR (aa.account_type='liability_payable' AND aa.non_trade))
                  AND aml.journal_id IN (SELECT account_journal_id FROM account_journal_account_journal_group_rel) THEN aml.balance ELSE 0 END)    AS ocl_ic
  FROM account_move_line aml JOIN account_account aa ON aa.id=aml.account_id
  WHERE aml.parent_state='posted' AND aml.date <= DATE '9999-12-31'
), rep_snap AS (
  SELECT SUM(cash_bank_delta) cash, SUM(ar_delta) ar, SUM(ar_ic_delta) ar_ic,
         SUM(ap_delta) ap, SUM(ap_ic_delta) ap_ic,
         SUM(other_current_assets_delta) oca, SUM(other_current_assets_ic_delta) oca_ic,
         SUM(other_current_liabilities_delta) ocl, SUM(other_current_liabilities_ic_delta) ocl_ic
    FROM finance_dashboard_daily WHERE date <= DATE '9999-12-31'
), src_flow AS (
  SELECT
   -SUM(CASE WHEN aa.account_type='income' THEN aml.balance ELSE 0 END)                        AS sales,
   -SUM(CASE WHEN aa.account_type='income'
                  AND aml.journal_id IN (SELECT account_journal_id FROM account_journal_account_journal_group_rel) THEN aml.balance ELSE 0 END)     AS sales_ic,
    SUM(CASE WHEN aa.account_type='expense_direct_cost' THEN aml.balance ELSE 0 END)           AS cogs,
    SUM(CASE WHEN aa.account_type='expense_direct_cost'
                  AND aml.journal_id IN (SELECT account_journal_id FROM account_journal_account_journal_group_rel) THEN aml.balance ELSE 0 END)     AS cogs_ic,
    SUM(CASE WHEN aa.account_type='expense' THEN aml.balance ELSE 0 END)                       AS opex,
   -SUM(CASE WHEN aa.account_type='income_other' THEN aml.balance ELSE 0 END)                  AS other_income,
    SUM(CASE WHEN aa.account_type='expense_depreciation' THEN aml.balance ELSE 0 END)          AS depreciation
  FROM account_move_line aml JOIN account_account aa ON aa.id=aml.account_id
  WHERE aml.parent_state='posted' AND aml.date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31'
), rep_flow AS (
  SELECT SUM(sales) sales, SUM(sales_ic) sales_ic, SUM(cogs) cogs, SUM(cogs_ic) cogs_ic,
         SUM(opex) opex, SUM(other_income) other_income, SUM(depreciation) depreciation
    FROM finance_dashboard_daily WHERE date BETWEEN DATE '0001-01-01' AND DATE '9999-12-31'
), cmp(measure, source_value, reporting_value) AS (
  SELECT 'cash',         src_snap.cash,  rep_snap.cash  FROM src_snap, rep_snap
  UNION ALL SELECT 'ar',        src_snap.ar,     rep_snap.ar     FROM src_snap, rep_snap
  UNION ALL SELECT 'ar_ic',     src_snap.ar_ic,  rep_snap.ar_ic  FROM src_snap, rep_snap
  UNION ALL SELECT 'ap',        src_snap.ap,     rep_snap.ap     FROM src_snap, rep_snap
  UNION ALL SELECT 'ap_ic',     src_snap.ap_ic,  rep_snap.ap_ic  FROM src_snap, rep_snap
  UNION ALL SELECT 'oca',       src_snap.oca,    rep_snap.oca    FROM src_snap, rep_snap
  UNION ALL SELECT 'oca_ic',    src_snap.oca_ic, rep_snap.oca_ic FROM src_snap, rep_snap
  UNION ALL SELECT 'ocl',       src_snap.ocl,    rep_snap.ocl    FROM src_snap, rep_snap
  UNION ALL SELECT 'ocl_ic',    src_snap.ocl_ic, rep_snap.ocl_ic FROM src_snap, rep_snap
  UNION ALL SELECT 'sales',     src_flow.sales,        rep_flow.sales        FROM src_flow, rep_flow
  UNION ALL SELECT 'sales_ic',  src_flow.sales_ic,     rep_flow.sales_ic     FROM src_flow, rep_flow
  UNION ALL SELECT 'cogs',      src_flow.cogs,         rep_flow.cogs         FROM src_flow, rep_flow
  UNION ALL SELECT 'cogs_ic',   src_flow.cogs_ic,      rep_flow.cogs_ic      FROM src_flow, rep_flow
  UNION ALL SELECT 'opex',      src_flow.opex,         rep_flow.opex         FROM src_flow, rep_flow
  UNION ALL SELECT 'other_income', src_flow.other_income, rep_flow.other_income FROM src_flow, rep_flow
  UNION ALL SELECT 'depreciation', src_flow.depreciation, rep_flow.depreciation FROM src_flow, rep_flow
)
-- numeric throughout: no float, so `= 0` is an exact test, not a tolerance.
SELECT measure,
       ROUND(source_value,2)                      AS source_value,
       ROUND(reporting_value,2)                   AS reporting_value,
       ROUND(reporting_value - source_value, 2)   AS difference,
       CASE WHEN ROUND(reporting_value - source_value, 2) = 0 THEN 'PASS' ELSE 'FAIL' END AS status
  FROM cmp ORDER BY measure;
