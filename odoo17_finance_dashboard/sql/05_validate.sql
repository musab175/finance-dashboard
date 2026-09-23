-- Validate the summary table against figures verified directly against Odoo.
WITH snap AS (   -- snapshots: cumulative deltas up to the as-of date
  SELECT
    SUM(cash_bank_delta) AS cash,
    SUM(ar_delta)        AS ar_all,
    SUM(ar_ic_delta)     AS ar_ic,
    SUM(ap_delta)        AS ap_all,
    SUM(ap_ic_delta)     AS ap_ic
  FROM finance_dashboard_daily
  WHERE date <= '2026-03-18' AND company_id IN (1,2,3,4,5,6,7,8,9,10)
), flow AS (     -- flows: summed over the MTD range
  SELECT SUM(sales) AS sales, SUM(cogs) AS cogs,
         SUM(other_income) AS oth, SUM(opex) AS opex
  FROM finance_dashboard_daily
  WHERE date BETWEEN '2026-03-01' AND '2026-03-18'
    AND company_id IN (1,2,3,4,5,6,7,8,9,10)
)
SELECT 'Cash & Bank'        AS measure, ROUND(snap.cash,2)                      AS from_summary, 2325326.72   AS expected FROM snap
UNION ALL SELECT 'Receivables (Odoo basis)', ROUND(snap.ar_all - snap.ar_ic,2),        11762424.19  FROM snap
UNION ALL SELECT 'Payables (Odoo basis, displayed)', ROUND(-(snap.ap_all - snap.ap_ic),2), -4740442.28 FROM snap
UNION ALL SELECT 'MTD Sales',         ROUND(flow.sales,2), 4160432.58 FROM flow
UNION ALL SELECT 'MTD COGS',          ROUND(flow.cogs,2),  3049973.75 FROM flow
UNION ALL SELECT 'MTD Other Income',  ROUND(flow.oth,2),   10447.31   FROM flow
UNION ALL SELECT 'MTD Operating Exp', ROUND(flow.opex,2),  83471.03   FROM flow;
