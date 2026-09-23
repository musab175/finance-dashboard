-- ===================================================================
-- Finance Dashboard summary layer (whole dashboard)
--
-- Basis decisions, all verified against Odoo on 2026-09-19:
--   * every measure is GENERAL-LEDGER based (account_move_line.balance
--     filtered by account_account.account_type) - the same basis Odoo's
--     Balance Sheet and P&L use. The old invoice-based AR/AP were the
--     only measures that disagreed with Odoo.
--   * AR/AP restricted to non_trade = false, matching Odoo's report lines.
--   * the intercompany-journal portion is stored SEPARATELY so the
--     dashboard can reproduce Odoo's journal-filtered figure by
--     subtraction, without re-scanning the ledger.
--
-- Flow vs snapshot:
--   * flow columns (sales, cogs, opex, other_income, depreciation) are
--     daily totals - SUM them over a date range.
--   * snapshot columns are stored as daily DELTAS, never as running
--     balances. A point-in-time balance is the cumulative sum of deltas
--     where date <= as_of. Storing deltas keeps backdated entries cheap
--     to correct: only the affected day is rewritten, not every later row.
-- ===================================================================

DROP TABLE IF EXISTS finance_dashboard_daily;
CREATE TABLE finance_dashboard_daily (
    company_id                      integer     NOT NULL,
    date                            date        NOT NULL,

    -- FLOW (sum over range)
    sales                           numeric(18,2) NOT NULL DEFAULT 0,
    cogs                            numeric(18,2) NOT NULL DEFAULT 0,
    opex                            numeric(18,2) NOT NULL DEFAULT 0,
    other_income                    numeric(18,2) NOT NULL DEFAULT 0,
    depreciation                    numeric(18,2) NOT NULL DEFAULT 0,

    -- SNAPSHOT DELTAS (cumulative-sum to a date; never sum as a range)
    cash_bank_delta                 numeric(18,2) NOT NULL DEFAULT 0,
    ar_delta                        numeric(18,2) NOT NULL DEFAULT 0,
    ap_delta                        numeric(18,2) NOT NULL DEFAULT 0,
    ar_ic_delta                     numeric(18,2) NOT NULL DEFAULT 0,
    ap_ic_delta                     numeric(18,2) NOT NULL DEFAULT 0,
    other_current_assets_delta      numeric(18,2) NOT NULL DEFAULT 0,
    other_current_liabilities_delta numeric(18,2) NOT NULL DEFAULT 0,

    CONSTRAINT finance_dashboard_daily_pk PRIMARY KEY (company_id, date)
);

-- AR/AP detail. Serves three things at once: the totals, the aging buckets
-- (bucket = as_of - date_maturity, so it cannot be pre-bucketed), and the
-- top-5 overdue partner rankings.
DROP TABLE IF EXISTS finance_dashboard_arap_daily;
CREATE TABLE finance_dashboard_arap_daily (
    company_id      integer     NOT NULL,
    date            date        NOT NULL,
    date_maturity   date,
    partner_id      integer,
    is_intercompany boolean     NOT NULL DEFAULT false,
    ar_amount       numeric(18,2) NOT NULL DEFAULT 0,
    ap_amount       numeric(18,2) NOT NULL DEFAULT 0
);
-- Deterministic grain key, required by the incremental merge in 03.
-- The grain contains two NULLABLE columns (date_maturity, partner_id), so the
-- index normalises them to sentinels. The STORED DATA IS UNCHANGED - NULLs stay
-- NULL; only the index and the merge predicate use the normalised form, so no
-- dashboard read query is affected.
--
-- Sentinel safety verified on the real data (2026-09-23): ZERO rows use
-- date_maturity = '9999-12-31' (max real value 2027-02-22) or partner_id = -1
-- (min real value 1), so normalisation cannot collide with a genuine value.
--
-- Uniqueness verified: 496,874 rows = 496,874 distinct normalised keys,
-- 0 collisions. Plain equality on these expressions is indexable, whereas
-- IS NOT DISTINCT FROM is not - that difference made the merge 43x faster.
CREATE UNIQUE INDEX finance_dashboard_arap_uk
    ON finance_dashboard_arap_daily
       (company_id, date,
        COALESCE(date_maturity, DATE '9999-12-31'),
        COALESCE(partner_id, -1),
        is_intercompany);

CREATE INDEX finance_dashboard_arap_daily_idx
    ON finance_dashboard_arap_daily (company_id, date);

-- Aging: arap_daily collapsed without partner_id. Created HERE rather than by
-- the refresh, so the daily refresh can replace its rows instead of dropping
-- the table. A DROP would take an ACCESS EXCLUSIVE lock (blocking dashboard
-- aging queries for the whole refresh) and would leave the table missing
-- entirely if the refresh failed part-way.
--
-- Column types deliberately match what the previous CREATE TABLE AS produced:
-- SUM(numeric(18,2)) yields unconstrained numeric, so these stay plain numeric
-- and the refreshed values are byte-identical to the old implementation.
DROP TABLE IF EXISTS finance_dashboard_aging_daily;
CREATE TABLE finance_dashboard_aging_daily (
    company_id      integer NOT NULL,
    date            date    NOT NULL,
    date_maturity   date,
    ar_amount       numeric,
    ap_amount       numeric
);
CREATE INDEX finance_dashboard_aging_idx
    ON finance_dashboard_aging_daily (company_id, date)
    INCLUDE (date_maturity, ar_amount, ap_amount);

-- Expense detail by account, for the "Expenses vs Last Month" table.
DROP TABLE IF EXISTS finance_dashboard_expense_daily;
CREATE TABLE finance_dashboard_expense_daily (
    company_id  integer     NOT NULL,
    date        date        NOT NULL,
    account_id  integer     NOT NULL,
    amount      numeric(18,2) NOT NULL DEFAULT 0,
    CONSTRAINT finance_dashboard_expense_daily_pk PRIMARY KEY (company_id, date, account_id)
);

-- Refresh bookkeeping: what range each company is covered for, and when it
-- was last rebuilt. Backdated entries are handled by recomputing a window,
-- so dirty_from records the earliest day needing rebuild.
DROP TABLE IF EXISTS finance_dashboard_coverage;
CREATE TABLE finance_dashboard_coverage (
    company_id      integer     NOT NULL PRIMARY KEY,
    covered_from    date,
    covered_to      date,
    dirty_from      date,
    last_refresh_at timestamp,
    last_refresh_ok boolean
);
