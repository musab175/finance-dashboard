-- Expense detail by account (includes COGS accounts: the dashboard's
-- "Expenses vs Last Month" table covers expense + expense_direct_cost).
INSERT INTO finance_dashboard_expense_daily (company_id, date, account_id, amount)
SELECT aml.company_id, aml.date, aml.account_id, SUM(aml.balance)
FROM account_move_line aml
JOIN account_account aa ON aa.id = aml.account_id
WHERE aml.parent_state = 'posted'
  AND aa.account_type IN ('expense','expense_direct_cost','expense_depreciation')
GROUP BY aml.company_id, aml.date, aml.account_id
-- Idempotent: this table has PRIMARY KEY (company_id, date, account_id), so a
-- bare re-INSERT would abort on duplicate keys and break the daily refresh.
ON CONFLICT (company_id, date, account_id) DO UPDATE SET
    amount = EXCLUDED.amount;

-- Aging table: arap_daily collapsed without partner_id (488k -> ~38k rows).
-- Buckets don't need partner detail; only the top-5 rankings do. This is a
-- 12x reduction and is what keeps the aging query fast.
--
-- Rows are REPLACED, not the table. The previous DROP TABLE + CREATE TABLE AS
-- took an ACCESS EXCLUSIVE lock for the whole refresh, blocking every dashboard
-- aging query, and a failure part-way left the table missing rather than merely
-- stale. DELETE+INSERT takes only row locks, keeps the index, and under MVCC
-- readers continue to see the previous rows until COMMIT.
-- The SELECT is unchanged, so the resulting values are identical.
DELETE FROM finance_dashboard_aging_daily;

INSERT INTO finance_dashboard_aging_daily (company_id, date, date_maturity, ar_amount, ap_amount)
SELECT company_id, date, date_maturity,
       SUM(ar_amount) AS ar_amount,
       SUM(ap_amount) AS ap_amount
FROM finance_dashboard_arap_daily
WHERE NOT is_intercompany
GROUP BY company_id, date, date_maturity;

-- IF NOT EXISTS: arap_daily is not dropped on a refresh (only its rows are
-- replaced), so this index survives and a bare CREATE INDEX would fail.
CREATE INDEX IF NOT EXISTS finance_dashboard_arap_partner_idx
  ON finance_dashboard_arap_daily (company_id, date)
  INCLUDE (date_maturity, partner_id, ar_amount, ap_amount)
  WHERE NOT is_intercompany AND partner_id IS NOT NULL;

-- Coverage bookkeeping. last_refresh_at is what the dashboard reports as its
-- data vintage, so it must be rewritten on every refresh, not inserted once.
-- covered_to is MAX(date) from the ledger and is NOT a freshness indicator on
-- this dataset: far-future-dated entries push it to 2205-10-18.
INSERT INTO finance_dashboard_coverage (company_id, covered_from, covered_to, last_refresh_at, last_refresh_ok)
SELECT company_id, MIN(date), MAX(date), now(), true
FROM finance_dashboard_daily GROUP BY company_id
ON CONFLICT (company_id) DO UPDATE SET
    covered_from    = EXCLUDED.covered_from,
    covered_to      = EXCLUDED.covered_to,
    last_refresh_at = EXCLUDED.last_refresh_at,
    last_refresh_ok = EXCLUDED.last_refresh_ok;

ANALYZE finance_dashboard_daily;
ANALYZE finance_dashboard_arap_daily;
ANALYZE finance_dashboard_aging_daily;
ANALYZE finance_dashboard_expense_daily;
