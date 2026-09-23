-- AR/AP detail by (company, posting date, maturity, partner).
-- Aging cannot be pre-bucketed: the bucket depends on as_of - date_maturity,
-- so maturity is kept and bucketed at read time.
--
-- INCREMENTAL MERGE (replaced DELETE-everything + INSERT-everything, 2026-09-23).
--
-- Why: the old approach rewrote all 496,874 rows on every refresh whether or not
-- anything changed (measured: n_tup_ins = 5 x 496,874, n_tup_upd = 0). Measured
-- over 8 refresh cycles on the 5433 clone:
--
--                        DELETE+INSERT      incremental merge
--   storage              118 -> 210 MB      80 MB, flat
--   WAL                  1,316 MB           174 MB
--   rows written         7,951,984          2,800
--   merge time           ~8 s               ~3.2 s
--
-- Correctness was byte-identical across every scenario tested: no change,
-- changed amounts, new rows, removed rows, NULL-bearing keys, and back-dated
-- changes (identical digests, 0 differences in either direction).
--
-- ATOMICITY: all statements below run inside the caller's single transaction
-- (05_refresh_all.sql via psql --single-transaction). There is no COMMIT here,
-- no batching and no intermediate state. The staging table is ON COMMIT DROP,
-- so it disappears with that same transaction whether it commits or rolls back.
--
-- The three steps are ordered UPDATE -> INSERT -> DELETE deliberately. DELETE
-- last means a row that merely CHANGED is never briefly absent, and the
-- explicit DELETE step is what prevents the orphaned-row problem that ruled out
-- a plain UPSERT (a key that disappears from the source is removed, not left
-- behind holding a stale amount).

-- ---------------------------------------------------------------------------
-- Staging: the new AR/AP result set. Aggregation is IDENTICAL to the previous
-- implementation - same filters, same grain, same intercompany derivation.
-- The numeric(18,2) casts match the target column types so values are exact.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE arap_new ON COMMIT DROP AS
SELECT
    aml.company_id,
    aml.date,
    aml.date_maturity,
    aml.partner_id,
    (aml.journal_id IN (SELECT r.account_journal_id
                        FROM account_journal_account_journal_group_rel r)) AS is_intercompany,
    SUM(CASE WHEN aa.account_type='asset_receivable'  THEN aml.balance ELSE 0 END)::numeric(18,2) AS ar_amount,
    SUM(CASE WHEN aa.account_type='liability_payable' THEN aml.balance ELSE 0 END)::numeric(18,2) AS ap_amount
FROM account_move_line aml
JOIN account_account aa ON aa.id = aml.account_id
WHERE aml.parent_state = 'posted'
  AND aa.non_trade = false
  AND aa.account_type IN ('asset_receivable','liability_payable')
GROUP BY aml.company_id, aml.date, aml.date_maturity, aml.partner_id,
         (aml.journal_id IN (SELECT r.account_journal_id
                        FROM account_journal_account_journal_group_rel r));

-- Matching index on the staging side, mirroring finance_dashboard_arap_uk.
CREATE INDEX arap_new_uk ON arap_new
    (company_id, date,
     COALESCE(date_maturity, DATE '9999-12-31'),
     COALESCE(partner_id, -1),
     is_intercompany);
ANALYZE arap_new;

-- ---------------------------------------------------------------------------
-- 1. UPDATE rows whose amounts actually changed.
--    The IS DISTINCT FROM guard suppresses no-op writes: an unchanged row
--    produces no new tuple version, so no heap write, no index write, no WAL.
-- ---------------------------------------------------------------------------
UPDATE finance_dashboard_arap_daily t
   SET ar_amount = s.ar_amount,
       ap_amount = s.ap_amount
  FROM arap_new s
 WHERE t.company_id = s.company_id
   AND t.date       = s.date
   AND COALESCE(t.date_maturity, DATE '9999-12-31') = COALESCE(s.date_maturity, DATE '9999-12-31')
   AND COALESCE(t.partner_id, -1)                   = COALESCE(s.partner_id, -1)
   AND t.is_intercompany = s.is_intercompany
   AND (t.ar_amount, t.ap_amount) IS DISTINCT FROM (s.ar_amount, s.ap_amount);

-- ---------------------------------------------------------------------------
-- 2. INSERT grain keys that did not exist before.
-- ---------------------------------------------------------------------------
INSERT INTO finance_dashboard_arap_daily (
    company_id, date, date_maturity, partner_id, is_intercompany, ar_amount, ap_amount)
SELECT s.company_id, s.date, s.date_maturity, s.partner_id, s.is_intercompany,
       s.ar_amount, s.ap_amount
FROM arap_new s
WHERE NOT EXISTS (
    SELECT 1 FROM finance_dashboard_arap_daily t
     WHERE t.company_id = s.company_id
       AND t.date       = s.date
       AND COALESCE(t.date_maturity, DATE '9999-12-31') = COALESCE(s.date_maturity, DATE '9999-12-31')
       AND COALESCE(t.partner_id, -1)                   = COALESCE(s.partner_id, -1)
       AND t.is_intercompany = s.is_intercompany);

-- ---------------------------------------------------------------------------
-- 3. DELETE grain keys that have disappeared from the source.
--    This is what keeps the table an exact mirror of the ledger. Without it the
--    merge would leave orphans (a corrected due date, cleared partner, unposted
--    move, flipped non_trade, or changed journal-group membership all retire a
--    key), which is precisely why a bare UPSERT was rejected.
-- ---------------------------------------------------------------------------
DELETE FROM finance_dashboard_arap_daily t
WHERE NOT EXISTS (
    SELECT 1 FROM arap_new s
     WHERE s.company_id = t.company_id
       AND s.date       = t.date
       AND COALESCE(s.date_maturity, DATE '9999-12-31') = COALESCE(t.date_maturity, DATE '9999-12-31')
       AND COALESCE(s.partner_id, -1)                   = COALESCE(t.partner_id, -1)
       AND s.is_intercompany = t.is_intercompany);
