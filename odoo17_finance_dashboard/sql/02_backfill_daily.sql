-- Main daily table: one pass over the ledger, full history.
-- The intercompany journals are read from the journal group's
-- excluded_journal_ids rather than hardcoded, so this script is portable
-- across databases where those journal IDs differ.
INSERT INTO finance_dashboard_daily (
    company_id, date, sales, cogs, opex, other_income, depreciation,
    cash_bank_delta, ar_delta, ap_delta, ar_ic_delta, ap_ic_delta,
    other_current_assets_delta, other_current_liabilities_delta)
SELECT
    aml.company_id,
    aml.date,
    -SUM(CASE WHEN aa.account_type='income'               THEN aml.balance ELSE 0 END),
     SUM(CASE WHEN aa.account_type='expense_direct_cost'  THEN aml.balance ELSE 0 END),
     SUM(CASE WHEN aa.account_type='expense'              THEN aml.balance ELSE 0 END),
    -SUM(CASE WHEN aa.account_type='income_other'         THEN aml.balance ELSE 0 END),
     SUM(CASE WHEN aa.account_type='expense_depreciation' THEN aml.balance ELSE 0 END),
     SUM(CASE WHEN aa.account_type='asset_cash'           THEN aml.balance ELSE 0 END),
     SUM(CASE WHEN aa.account_type='asset_receivable'  AND NOT aa.non_trade THEN aml.balance ELSE 0 END),
     SUM(CASE WHEN aa.account_type='liability_payable' AND NOT aa.non_trade THEN aml.balance ELSE 0 END),
     SUM(CASE WHEN aa.account_type='asset_receivable'  AND NOT aa.non_trade
                AND aml.journal_id IN (SELECT r.account_journal_id
                        FROM account_journal_account_journal_group_rel r) THEN aml.balance ELSE 0 END),
     SUM(CASE WHEN aa.account_type='liability_payable' AND NOT aa.non_trade
                AND aml.journal_id IN (SELECT r.account_journal_id
                        FROM account_journal_account_journal_group_rel r) THEN aml.balance ELSE 0 END),
     -- Odoo Balance Sheet line 55 "Current Assets":
     --   asset_current OR (asset_receivable AND non_trade)
     SUM(CASE WHEN aa.account_type='asset_current'
               OR (aa.account_type='asset_receivable' AND aa.non_trade)
              THEN aml.balance ELSE 0 END),
     -- Odoo Balance Sheet line 61 "Current Liabilities":
     --   liability_current OR liability_credit_card OR (liability_payable AND non_trade)
     -- Stored as raw SUM(balance); Odoo displays this line as -sum.
     SUM(CASE WHEN aa.account_type IN ('liability_current','liability_credit_card')
               OR (aa.account_type='liability_payable' AND aa.non_trade)
              THEN aml.balance ELSE 0 END)
FROM account_move_line aml
JOIN account_account aa ON aa.id = aml.account_id
WHERE aml.parent_state = 'posted'
  AND aa.account_type IN ('income','expense_direct_cost','expense','income_other',
                          'expense_depreciation','asset_cash','asset_receivable',
                          'liability_payable','asset_current','liability_current',
                          'liability_credit_card')
GROUP BY aml.company_id, aml.date
-- Idempotent: safe to re-run against an already-populated table.
-- Without this the script aborts on the first duplicate key, because
-- finance_dashboard_daily has PRIMARY KEY (company_id, date) and this INSERT
-- previously only worked against the empty table 01_create_summary.sql creates.
-- Every one of the table's 12 non-key columns is produced by the SELECT above,
-- so refreshing all of them from EXCLUDED reproduces exactly what a fresh
-- insert would write. No other table is touched - in particular
-- finance_dashboard_coverage is written by 04_backfill_expense_and_derived.sql,
-- not here.
--
-- Known limitation: a (company_id, date) row that exists in the table but no
-- longer appears in the SELECT (its source lines were deleted or unposted) is
-- not visited by ON CONFLICT and keeps its previous values. A true full rebuild
-- still requires 01_create_summary.sql, which drops and recreates the table.
ON CONFLICT (company_id, date) DO UPDATE SET
    sales                           = EXCLUDED.sales,
    cogs                            = EXCLUDED.cogs,
    opex                            = EXCLUDED.opex,
    other_income                    = EXCLUDED.other_income,
    depreciation                    = EXCLUDED.depreciation,
    cash_bank_delta                 = EXCLUDED.cash_bank_delta,
    ar_delta                        = EXCLUDED.ar_delta,
    ap_delta                        = EXCLUDED.ap_delta,
    ar_ic_delta                     = EXCLUDED.ar_ic_delta,
    ap_ic_delta                     = EXCLUDED.ap_ic_delta,
    other_current_assets_delta      = EXCLUDED.other_current_assets_delta,
    other_current_liabilities_delta = EXCLUDED.other_current_liabilities_delta;
