-- CROSS-TABLE INVARIANTS. Additive companion to 06b_validate_live_inline.sql.
--
-- PURPOSE: 06b proves finance_dashboard_daily against the ledger. This file
-- anchors the other three data tables to it, so every financial figure the
-- dashboard shows is gated before commit.
--
--   checks                 kind             what a PASS proves
--   arap    vs daily  (4)  independent      02 and 03 read the ledger
--                                           separately and agree (03 at the
--                                           partner and maturity grain)
--   expense vs daily  (1)  independent      02 and 04 read the ledger
--                                           separately and agree (04 at the
--                                           account grain)
--   aging   vs arap   (2)  by construction  04 builds aging from arap, so this
--                                           only proves the aging step ran on
--                                           the arap just built
--
-- NOT CHECKED: finance_dashboard_coverage - refresh bookkeeping, including the
-- last_refresh_at the dashboard displays as its data vintage. No figure.
--
-- COST: reads only the four reporting data tables - no ledger scan. That is why
-- this is a separate file: it can also run on its own, cheaply, against a layer
-- that already exists.
--
-- NEW POSTINGS CANNOT MAKE THIS FAIL - for a layer built by refresh_full().
-- Odoo's cursor is REPEATABLE READ, so all five tables come from one snapshot
-- of the ledger and both sides of every check move together. A FAIL then means
-- a build defect, or a ledger balance with more than two decimals rounded at
-- two different grains. Investigate - never add a tolerance. (A layer built by
-- psql runs at READ COMMITTED, a new snapshot per statement, so a posting made
-- mid-refresh could make one of these checks fail.)
--
-- CONDITIONAL AGGREGATION, DELIBERATELY. Subsets are summed as
-- SUM(CASE WHEN ... THEN x ELSE 0 END) over the WHOLE table, never filtered
-- with WHERE. SUM is then NULL only when a table is EMPTY, and NULL falls
-- through to FAIL - an empty build must never pass. A WHERE filter would also
-- go NULL when a category is legitimately absent (a database with no
-- intercompany journal) and fail for no reason.
--
-- PORTABILITY: pure SQL, a single statement, no parameters, no psql
-- meta-commands. Runs unchanged through psql AND through Odoo's
-- env.cr.execute(). Same rules as 06b: no percent sign anywhere in this file,
-- and no COALESCE on either side of a check.
--
-- ORCHESTRATOR USE: after refresh_full() and 06b, BEFORE commit, in the same
-- transaction. Any row whose status is not PASS means rollback.

WITH d AS (
  SELECT SUM(ar_delta) ar, SUM(ar_ic_delta) ar_ic,
         SUM(ap_delta) ap, SUM(ap_ic_delta) ap_ic,
         SUM(opex + cogs + depreciation) exp_total
    FROM finance_dashboard_daily
), a AS (
  SELECT SUM(ar_amount) ar,
         SUM(CASE WHEN is_intercompany THEN ar_amount ELSE 0 END) ar_ic,
         SUM(CASE WHEN is_intercompany THEN 0 ELSE ar_amount END) ar_trade,
         SUM(ap_amount) ap,
         SUM(CASE WHEN is_intercompany THEN ap_amount ELSE 0 END) ap_ic,
         SUM(CASE WHEN is_intercompany THEN 0 ELSE ap_amount END) ap_trade
    FROM finance_dashboard_arap_daily
), g AS (
  SELECT SUM(ar_amount) ar, SUM(ap_amount) ap FROM finance_dashboard_aging_daily
), e AS (
  SELECT SUM(amount) total FROM finance_dashboard_expense_daily
), cmp(invariant, left_value, right_value) AS (
            SELECT 'arap.ar    = daily.ar_delta',    a.ar,    d.ar        FROM a, d
  UNION ALL SELECT 'arap.ar_ic = daily.ar_ic_delta', a.ar_ic, d.ar_ic     FROM a, d
  UNION ALL SELECT 'arap.ap    = daily.ap_delta',    a.ap,    d.ap        FROM a, d
  UNION ALL SELECT 'arap.ap_ic = daily.ap_ic_delta', a.ap_ic, d.ap_ic     FROM a, d
  UNION ALL SELECT 'aging.ar   = arap.ar non-IC',    g.ar,    a.ar_trade  FROM g, a
  UNION ALL SELECT 'aging.ap   = arap.ap non-IC',    g.ap,    a.ap_trade  FROM g, a
  UNION ALL SELECT 'expense    = opex+cogs+dep',     e.total, d.exp_total FROM e, d
)
SELECT invariant,
       ROUND(left_value, 2)               AS left_value,
       ROUND(right_value, 2)              AS right_value,
       ROUND(left_value - right_value, 2) AS difference,
       CASE WHEN ROUND(left_value - right_value, 2) = 0 THEN 'PASS' ELSE 'FAIL' END AS status
  FROM cmp ORDER BY invariant;
