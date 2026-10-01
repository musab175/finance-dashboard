-- BOOTSTRAP GATE: unknown account-type guard. 2026-10-01.
--
-- WHY: 02_backfill_daily.sql classifies eleven account_types explicitly and its
--   WHERE clause silently DROPS anything else. Odoo's Balance Sheet line 56
--   (Prepayments, account_type='asset_prepayments') is a live example: it is a
--   genuine Current Assets component that our layer does not model. It costs
--   exactly 0.00 today because this chart of accounts contains zero such
--   accounts - verified against Odoo's own engine, which returned
--   "Prepayments 0.0" in every one of the 2026-10-01 validation runs.
--   If the chart of accounts ever gains one, Current Assets would quietly
--   understate with no error anywhere. This guard converts that silent drift
--   into a loud, blocking failure.
--
-- SCOPE: checks account_account (680 rows, milliseconds). Deliberately NOT
--   account_move_line - that is a 77-second full scan and adds nothing, because
--   a line cannot reference an account that does not exist.
--
-- TWO LISTS, BOTH DELIBERATE:
--   CLASSIFIED    - types 02_backfill_daily.sql maps to a reporting column.
--   OUT_OF_SCOPE  - types we knowingly exclude (fixed assets, equity,
--                   non-current items). They are not dashboard measures.
--   Anything in NEITHER list is unknown and fails the bootstrap.
--   asset_prepayments is deliberately absent from both: catching it is the point.

WITH classified(t) AS (VALUES
    ('income'),('income_other'),('expense'),('expense_direct_cost'),
    ('expense_depreciation'),('asset_cash'),('asset_receivable'),
    ('liability_payable'),('asset_current'),('liability_current'),
    ('liability_credit_card')
), out_of_scope(t) AS (VALUES
    ('asset_fixed'),('asset_non_current'),('equity'),('equity_unaffected'),
    ('liability_non_current'),('off_balance')
), unknown AS (
    SELECT aa.account_type, count(*) AS accounts,
           min(aa.code) AS example_code
      FROM account_account aa
     WHERE aa.account_type IS NULL
        OR (aa.account_type NOT IN (SELECT t FROM classified)
        AND aa.account_type NOT IN (SELECT t FROM out_of_scope))
     GROUP BY aa.account_type
)
SELECT CASE WHEN (SELECT count(*) FROM unknown) = 0
            THEN 'GUARD PASS: every account_type is either classified or explicitly out of scope'
            ELSE 'GUARD FAIL: unclassified account_type(s) present - bootstrap must not proceed'
       END AS guard_result;

-- Detail rows. Empty on PASS; on FAIL this names exactly what to classify.
WITH classified(t) AS (VALUES
    ('income'),('income_other'),('expense'),('expense_direct_cost'),
    ('expense_depreciation'),('asset_cash'),('asset_receivable'),
    ('liability_payable'),('asset_current'),('liability_current'),
    ('liability_credit_card')
), out_of_scope(t) AS (VALUES
    ('asset_fixed'),('asset_non_current'),('equity'),('equity_unaffected'),
    ('liability_non_current'),('off_balance')
)
SELECT aa.account_type AS unclassified_type, count(*) AS accounts,
       min(aa.code) AS example_code, max(aa.code) AS another_code
  FROM account_account aa
 WHERE aa.account_type IS NULL
    OR (aa.account_type NOT IN (SELECT t FROM classified)
    AND aa.account_type NOT IN (SELECT t FROM out_of_scope))
 GROUP BY aa.account_type ORDER BY 1;
