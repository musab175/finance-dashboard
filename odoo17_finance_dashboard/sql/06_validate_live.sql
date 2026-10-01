-- DATASET-INDEPENDENT VALIDATION GATE. 2026-10-01.
--
-- REPLACES 05_validate.sql FOR BOOTSTRAP USE. 05_validate.sql is NOT deleted and
-- NOT edited: its seven constants are a historical record of the figures verified
-- against Odoo on 141.145.154.249:5432/gftuae_new on 2026-09-19, and they remain
-- the correct check for THAT dataset. They cannot gate a replaced database - the
-- README says so, and on 2026-10-01 two of its seven lines failed on a ledger ten
-- days newer, which is correct behaviour for a constant, not a defect.
--
-- METHOD: recompute each measure straight from account_move_line using Odoo's OWN
-- stored domains (read from account_report_expression, reports 5 and 8), then diff
-- against the reporting tables in the SAME database. Works on any dataset.
--
-- HONEST LIMIT: the "source" side re-expresses 02_backfill_daily.sql's CASE logic,
-- so this is a cross-check of the BUILD (did the aggregation land correctly), not
-- an independent audit of the DEFINITIONS. The definitions were separately proven
-- equal to Odoo's report engine on 2026-10-01: 85 of 85 comparisons at exactly
-- 0.00 across 3 company scopes, 3 dates and 2 P&L periods. This gate protects that
-- proven state; it does not re-derive it.
--
-- USAGE:
--   psql "$URI" -v as_of=2026-03-18 -v df=2026-03-01 -v dt=2026-03-18 \
--        -f 06_validate_live.sql
\if :{?as_of} \else \set as_of '2026-03-18' \endif
\if :{?df}    \else \set df    '2026-03-01' \endif
\if :{?dt}    \else \set dt    '2026-03-18' \endif

WITH ic AS (SELECT array_agg(account_journal_id) AS j
              FROM account_journal_account_journal_group_rel),
src_snap AS (
  SELECT
    SUM(CASE WHEN aa.account_type='asset_cash' THEN aml.balance ELSE 0 END)                   AS cash,
    SUM(CASE WHEN aa.account_type='asset_receivable' AND NOT aa.non_trade
             THEN aml.balance ELSE 0 END)                                                     AS ar,
    SUM(CASE WHEN aa.account_type='asset_receivable' AND NOT aa.non_trade
                  AND aml.journal_id = ANY((SELECT j FROM ic)) THEN aml.balance ELSE 0 END)    AS ar_ic,
    SUM(CASE WHEN aa.account_type='liability_payable' AND NOT aa.non_trade
             THEN aml.balance ELSE 0 END)                                                     AS ap,
    SUM(CASE WHEN aa.account_type='liability_payable' AND NOT aa.non_trade
                  AND aml.journal_id = ANY((SELECT j FROM ic)) THEN aml.balance ELSE 0 END)    AS ap_ic,
    SUM(CASE WHEN aa.account_type='asset_current'
                  OR (aa.account_type='asset_receivable' AND aa.non_trade)
             THEN aml.balance ELSE 0 END)                                                     AS oca,
    SUM(CASE WHEN (aa.account_type='asset_current'
                   OR (aa.account_type='asset_receivable' AND aa.non_trade))
                  AND aml.journal_id = ANY((SELECT j FROM ic)) THEN aml.balance ELSE 0 END)    AS oca_ic,
    SUM(CASE WHEN aa.account_type IN ('liability_current','liability_credit_card')
                  OR (aa.account_type='liability_payable' AND aa.non_trade)
             THEN aml.balance ELSE 0 END)                                                     AS ocl,
    SUM(CASE WHEN (aa.account_type IN ('liability_current','liability_credit_card')
                   OR (aa.account_type='liability_payable' AND aa.non_trade))
                  AND aml.journal_id = ANY((SELECT j FROM ic)) THEN aml.balance ELSE 0 END)    AS ocl_ic
  FROM account_move_line aml JOIN account_account aa ON aa.id=aml.account_id
  WHERE aml.parent_state='posted' AND aml.date <= DATE :'as_of'
), rep_snap AS (
  SELECT SUM(cash_bank_delta) cash, SUM(ar_delta) ar, SUM(ar_ic_delta) ar_ic,
         SUM(ap_delta) ap, SUM(ap_ic_delta) ap_ic,
         SUM(other_current_assets_delta) oca, SUM(other_current_assets_ic_delta) oca_ic,
         SUM(other_current_liabilities_delta) ocl, SUM(other_current_liabilities_ic_delta) ocl_ic
    FROM finance_dashboard_daily WHERE date <= DATE :'as_of'
), src_flow AS (
  SELECT
   -SUM(CASE WHEN aa.account_type='income' THEN aml.balance ELSE 0 END)                        AS sales,
   -SUM(CASE WHEN aa.account_type='income'
                  AND aml.journal_id = ANY((SELECT j FROM ic)) THEN aml.balance ELSE 0 END)     AS sales_ic,
    SUM(CASE WHEN aa.account_type='expense_direct_cost' THEN aml.balance ELSE 0 END)           AS cogs,
    SUM(CASE WHEN aa.account_type='expense_direct_cost'
                  AND aml.journal_id = ANY((SELECT j FROM ic)) THEN aml.balance ELSE 0 END)     AS cogs_ic,
    SUM(CASE WHEN aa.account_type='expense' THEN aml.balance ELSE 0 END)                       AS opex,
   -SUM(CASE WHEN aa.account_type='income_other' THEN aml.balance ELSE 0 END)                  AS other_income,
    SUM(CASE WHEN aa.account_type='expense_depreciation' THEN aml.balance ELSE 0 END)          AS depreciation
  FROM account_move_line aml JOIN account_account aa ON aa.id=aml.account_id
  WHERE aml.parent_state='posted' AND aml.date BETWEEN DATE :'df' AND DATE :'dt'
), rep_flow AS (
  SELECT SUM(sales) sales, SUM(sales_ic) sales_ic, SUM(cogs) cogs, SUM(cogs_ic) cogs_ic,
         SUM(opex) opex, SUM(other_income) other_income, SUM(depreciation) depreciation
    FROM finance_dashboard_daily WHERE date BETWEEN DATE :'df' AND DATE :'dt'
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
