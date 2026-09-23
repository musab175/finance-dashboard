# Finance Dashboard — Accuracy Audit vs Odoo Balance Sheet

**Date:** 2026-09-19
**Database:** `gftuae_new` @ 141.145.154.249
**Reference reports:** Odoo Accounting → Reporting → Balance Sheet, Profit and Loss
**Scope:** Cash & Bank, Receivables, Payables, P&L (Sales / COGS / OpEx / Profit)

This records what was compared, what was wrong, what was fixed, and what is still
open. Written after the dashboard's figures disagreed with the Balance Sheet.

---

## The one-line diagnosis

The dashboard computes most measures from the **general ledger**
(`account_move_line.balance` filtered by `account_account.account_type`) — the
same basis Odoo uses. Those all agree with Odoo. Only **Receivables and
Payables** are computed from **invoices** (`account_move`), and those are the
only two measures that disagree. Every defect below traces back to that split.

Verified at 18 Mar 2026, all 10 companies:

| Measure | Dashboard | Odoo | |
|---------|-----------|------|---|
| Cash & Bank | 2,325,327 | 2,325,326.72 | match |
| Total Sales (MTD) | 4,160,433 | 4,160,432.58 | match |
| COGS (MTD) | 3,049,974 | 3,049,973.75 | match |
| Other Income (MTD) | 10,447 | 10,447.31 | match |
| Operating Expenses (MTD) | 83,471 | 83,471.03 | match |
| Gross Profit (MTD) | 1,110,459 | 1,110,458.83 | match |
| Net Profit (MTD) | 1,037,435 | 1,037,435.11 | match |
| **Total Receivables** | 9,406,921 → **8,970,952** | 11,762,711 | **differs** |
| **Total Payables** | 7,109,142 → **−2,573,063** | −4,720,532 | **differs** |

---

## Summary

| # | Measure | Defect | Impact (18 Mar 2026, all 10 companies) | Status |
|---|---------|--------|---------------------------------------|--------|
| 1 | Cash & Bank | Accounts chosen via journal `default_account_id` instead of `account_type` | 1 account missed (`101211 Petty Cash - HR`), AED 0 today | **Fixed** |
| 2 | Cash & Bank | Summed raw balances; no per-line rounding, no currency scaling | AED 0 today (single currency) | **Fixed** |
| 3 | Receivables | Intercompany invoices counted as receivable | **AED 13,511,700.57 overstated** | **Fixed** |
| 4 | AR **and** AP | Summed `amount_residual` (unsigned, document currency) instead of `amount_residual_signed` | **AR +435,969.56 / AP +4,536,078.96 overstated** | **Fixed** |
| 5 | AR and AP | Uses *today's* residual, not the residual as of the report date | ~AED 2.36m (AR) | **Open** |
| 6 | AR and AP | No `non_trade` concept — cannot exclude PDC / On Account accounts | PDC Payables −4,507,887.16 excluded by Odoo, included by us | **Open** |
| 7 | Top 5 Customers / Suppliers | Intercompany partners not excluded (totals are, the rankings are not) | Group companies appear as top overdue parties | **Open** |
| 8 | *(Odoo config, not our code)* | "P & L Without Inter Company" journal group splits balanced intercompany entries — excludes one side, keeps the other via `Operational Journal` | Balance Sheet AR understated ~13.5m; Payables flipped to a fake −4.7m debit | **Finance to fix** |

---

## Defect 4 — `amount_residual` vs `amount_residual_signed` (the big one)

`_ar_ap_aggregate` summed `amount_residual`. That field is **unsigned** and in
the **document's** currency. Two failures in one field choice:

1. **Credit notes added instead of subtracting.** A refund's residual is
   positive, so `out_invoice + out_refund` (and `in_invoice + in_refund`)
   inflated both totals.
2. **Foreign-currency documents were summed unconverted.**

Measured at 18 Mar 2026, excluding intercompany:

| move_type | `amount_residual` (was) | `amount_residual_signed` (now) |
|-----------|------------------------|-------------------------------|
| out_invoice | 9,188,936.70 | 9,188,936.70 |
| out_refund | **+217,984.78** | **−217,984.78** |
| in_invoice | 4,462,879.98 | **−5,253,118.49** |
| in_refund | **+2,646,262.47** | **+2,680,055.00** |

Note `in_invoice` differs in *magnitude* too — that is the currency conversion.

**Effect:** AR 9,406,921.48 → **8,970,951.92**. AP +7,109,142.45 →
**−2,573,063.49**, an overstatement of AED 4.54m driven by vendor credit notes
totalling 2,646,262.47 (one single note is AED 2,000,000, previously *added* to
what we owed instead of deducted).

This also explains the sign anomaly: AP now carries the **same sign as Odoo**
(a net debit position). The earlier "opposite signs" finding was our bug, not a
ledger anomaly.

Aging buckets still reconcile exactly to the total after the change
(8,970,951.92).

---

## Payables — how Odoo computes it

```sql
-- account_report_expression id 62, subformula '-sum' (NEGATES the result)
[('account_id.account_type', '=', 'liability_payable'),
 ('account_id.non_trade', '=', False)]
```

Payable accounts in this chart:

| Account | non_trade | In Odoo's line? | GL balance @ 18 Mar |
|---------|-----------|-----------------|---------------------|
| 200001–200011 (per-division payables) | false | yes | see below |
| **200010 PDC Payables** | **true** | **no** | −4,507,887.16 |
| 200012 Inter Company Payable | false | yes | 0.00 |

Four-way comparison at 18 Mar 2026:

| Variant | Amount |
|---------|--------|
| Odoo GL, all journals | +8,523,229.80 |
| **Odoo GL, excl. intercompany journals** | **−4,740,442.28** |
| Our method, all journals | 20,372,305.95 |
| Our method, excl. intercompany (before defect 4 fix) | 7,109,142.45 |
| Our method, after defect 4 fix | **−2,573,063.49** |

The screenshot shows −4,720,532.18 vs our replication −4,740,442.28; the
19,910.10 drift is post-cutover backdated entries (the screenshot is from the
frozen `gftuae_1_8_26` — see Part 3).

Intercompany removal is consistent across both methods: it strips 13,263,163.50
from ours and 13,263,672.08 from Odoo's, agreeing within AED 509.

The receivable side has the same `non_trade` pattern: `102020 PDC Receivable`
and `102021 On Account Receivable` are both flagged and excluded by Odoo.

---

## The journal filter is broken — Balance Sheet AR/AP are NOT ground truth

The "P & L Without Inter Company" journal group excludes the two intercompany
journals, but the **offsetting halves of those same entries were booked through
`Operational Journal`**, which the group leaves included. The filter therefore
splits balanced double entries, counting one side and dropping the other.

Balance on the intercompany control accounts, by journal, at 18 Mar 2026:

| Account | Journal | Balance | In filter? |
|---------|---------|---------|------------|
| 102023 Inter Company Receivable | `01- Inter Company Sales` (56) | **+13,496,764.61** | **excluded** |
| 102023 Inter Company Receivable | `Operational Journal` (8) | **−13,488,459.48** | included |
| 200012 Inter Company Payable | `01 - Inter Company Purchase` (57) | **−13,262,601.08** | **excluded** |
| 200012 Inter Company Payable | `Operational Journal` (8) | **+13,262,147.58** | included |

Net effect on each control account:

| Account | No filter | With the filter |
|---------|-----------|-----------------|
| Inter Company Receivable | +251,949.69 | **−13,244,814.92** |
| Inter Company Payable | **0.00** | **+13,262,601.08** |

So the filtered Balance Sheet **understates Receivables** by ~13.5m and leaves
**Payables holding an unmatched +13.26m debit**, which is what makes the
Payables line read −4,720,532.18, as though vendors owed the group money.

Proof: with the journal filter removed ("All Journals"), Odoo's own Payables
line returns **+8,523,229.80** — a normal credit balance.

**Consequence:** the Balance Sheet's Receivables and Payables lines in the
audit screenshots are artifacts of this filter and must not be used as accuracy
targets. Cash & Bank is unaffected (cash journals take no part in intercompany
pairings) and did match exactly throughout.

### Correct basis

Exclude the intercompany **accounts** (102023, 200012) outright rather than
filtering by journal — then both halves of every intercompany entry disappear
together and nothing is left unpaired. No journal filter is needed.

| Basis (18 Mar 2026, all 10 companies) | Receivables | Payables (owed) |
|---------------------------------------|-------------|-----------------|
| Odoo, All Journals | 25,275,342.76 | 8,523,229.80 |
| Odoo, "P&L Without Inter Company" (screenshots) | 11,762,424.19 | **−4,740,442.28** |
| **Clean trade (IC accounts excluded)** | **25,023,393.07** | **8,523,229.80** |
| Our dashboard (invoice basis) | 8,970,951.92 | 2,573,063.49 |

Two cross-checks confirm the clean basis: clean-trade AP equals the All-Journals
figure exactly (with no filter the IC account nets to zero, so removing it
changes nothing), and clean-trade AR differs from All-Journals AR by
251,949.69 — exactly the IC receivable account's unfiltered net balance.

The gap that remains between our dashboard and the clean GL basis is the
invoice-vs-ledger split (defects 5 and 6): point-in-time residuals,
unreconciled payments, and ledger entries that are not invoices.

**Action for finance:** the journal group needs fixing — every report using it
carries this distortion, not just this dashboard comparison.

---

## P&L — already correct, and why the screenshot looked wrong

Odoo's P&L lines (report id 8):

| Line | Formula | Ours | Same? |
|------|---------|------|-------|
| Operating Income | `-sum` of `account_type='income'` | GL, same | yes |
| Cost of Revenue | `sum` of `expense_direct_cost` | GL, same | yes |
| Other Income | `-sum` of `income_other` | GL, same | yes |
| Expenses | `sum` of `expense` | GL, same | yes |
| Depreciation | `sum` of `expense_depreciation` | **not computed** | zero activity in this DB |
| Gross Profit | `OPINC - COS` | same | yes |
| Net Profit | `OPINC + OIN - COS - EXP - DEP` | same (minus DEP) | yes |

Computed against `gftuae_new` for the dashboard's actual MTD window
(1–18 Mar 2026) every figure matched to the cent, as shown in the table at the
top of this document.

**The P&L screenshot is not a valid comparison target** for the dashboard:
- it covers **FY2026 (Jan–Dec)**, the dashboard shows **MTD March**;
- it is from the frozen `gftuae_1_8_26`, missing Aug–Dec data;
- its journal filter is a specific ~33-journal set ("P & L Without Inter
  Company, 02INV, 02STJ, 02BIL, SLR and 29 others"), not simply "exclude
  intercompany".

For the record, FY2026 on `gftuae_new`: Operating Income 55,323,509.67 all
journals / 50,750,276.21 excluding intercompany, vs the screenshot's
44,562,532.43 — the difference is dominated by the missing months and the
journal subset, not by a formula error.

---

## How Odoo actually computes these

Both lines come from the Enterprise `account_reports` module (license `OEEL-1`,
not in the public GitHub repo). The engine source on this server is at
`/mnt/enterprise-addons/addons_ent/addons/account_reports/models/account_report.py`.

Definitions live in the database, not in code:

```sql
SELECT arl.name->>'en_US', are.engine, are.formula, are.date_scope
FROM account_report_line arl
JOIN account_report_expression are ON are.report_line_id = arl.id
WHERE arl.report_id = 5;
```

| Line | Formula | Date scope |
|------|---------|------------|
| Bank and Cash Accounts | `[('account_id.account_type','=','asset_cash')]` | `strict_range` |
| Receivables | `[('account_id.account_type','=','asset_receivable'), ('account_id.non_trade','=',False)]` | `strict_range` |

Two engine behaviours matter:

1. **`strict_range` → `from_beginning` for the Balance Sheet.** `_standardize_date_scope_for_date_range`
   (line 2485) converts it because the Balance Sheet has `filter_date_range = False`.
   `_get_date_bounds_info` (line 674) then leaves `date_from = None`, so the date
   filter is only `date <= date_to` — **cumulative since inception, no lower bound.**
2. **Per-line rounding and currency scaling** (line 3031):
   `SUM(ROUND(balance * currency_table.rate, currency_table.precision))` —
   rounded per line *before* summing, each line scaled by its company's rate.

Company scope comes from the browser's company switcher (`filter_multi_company = 'selector'`),
**not** a report filter chip — so the same report gives different numbers depending
on which companies are ticked. This caused significant confusion during the audit.

---

## Part 1 — Cash & Bank Balance

### Odoo's query (extracted verbatim via `_query_get`)

```sql
SELECT COALESCE(SUM(ROUND(account_move_line.balance * currency_table.rate,
                          currency_table.precision)), 0.0)
FROM "account_move_line"
LEFT JOIN "account_account" AS "account_move_line__account_id"
       ON ("account_move_line"."account_id" = "account_move_line__account_id"."id")
JOIN (VALUES (1, 1.0, 2)) AS currency_table(company_id, rate, precision)
       ON currency_table.company_id = account_move_line.company_id
WHERE ("account_move_line"."display_type" NOT IN ('line_section','line_note')
       OR "account_move_line"."display_type" IS NULL)
  AND "account_move_line"."company_id" IN (...)
  AND "account_move_line"."journal_id" IN (...)
  AND "account_move_line"."date" <= '<as_of>'
  AND "account_move_line"."parent_state" = 'posted'
  AND "account_move_line__account_id"."account_type" = 'asset_cash';
```

### What we had (before)

```python
journals = env['account.journal'].search([('type','in',['bank','cash']), ...])
cash_accounts = journals.mapped('default_account_id').ids   # ← defect
# then: read_group(domain, ['balance:sum'])                 # ← defect
```

### Defect 1 — account selection

Deriving cash accounts from each journal's `default_account_id` returned **20**
accounts. Odoo's `account_type = 'asset_cash'` returns **21**. The missing one,
`101211 Petty Cash - HR`, has no journal pointing at it. It currently has zero
postings, so today the numbers were unaffected — but the figure would have
silently drifted the moment that account was used.

### Defect 2 — summation

We used `SUM(balance)`. Odoo rounds **each line** to the display currency's
precision and scales it by the company's conversion rate before summing.
`account_move_line.balance` is stored in the *line's own company currency*, so a
plain cross-company `SUM` adds unlike units together once a non-AED company exists.
All 10 companies are AED today (rate = 1), so measured drift was **0.0000** across
32,523 lines — this was a latent, not an active, defect.

### Fix

`_account_balance` now selects on `account_type = 'asset_cash'`, and the new
`_sum_balance()` helper reproduces Odoo's query shape exactly — building a
`(VALUES ...)` currency table and applying `ROUND((balance * rate)::numeric, precision)`
per line before summing.

### Verification

| As of | Odoo | Dashboard | |
|-------|------|-----------|---|
| 10 Mar 2026 (company 1) | 1,357,330.23 | 1,357,330.23 | exact |
| 5 May 2026 (company 1) | 2,864,404.71 | 2,864,404.71 | exact |
| 18 Mar 2026 (all 10) | 2,325,326.72 | 2,325,327 | exact (display rounding) |

**Cash & Bank is correct.**

---

## Part 2 — Total Receivables

### Odoo's query

```sql
SELECT COALESCE(SUM(ROUND(aml.balance * ct.rate, ct.precision)), 0.0)
FROM account_move_line aml
LEFT JOIN account_account aa ON aa.id = aml.account_id
JOIN (VALUES (1,1.0,2),(2,1.0,2),...) AS ct(company_id, rate, precision)
     ON ct.company_id = aml.company_id
WHERE aml.company_id IN (1,...,10)
  AND aml.journal_id NOT IN (56,57)        -- "P & L Without Inter Company"
  AND aml.date <= '2026-03-18'
  AND aml.parent_state = 'posted'
  AND aa.account_type = 'asset_receivable'
  AND aa.non_trade = false;
```

This is a **general-ledger balance** on trade receivable accounts.

### What we had

```sql
SELECT SUM(amount_residual)
FROM account_move
WHERE move_type IN ('out_invoice','out_refund')
  AND state = 'posted'
  AND payment_state IN ('not_paid','partial')
  AND company_id = ANY(...)
  AND invoice_date <= '2026-03-18';
```

This is a **sum of open-invoice residuals** — a different basis entirely. It is the
right basis for aging buckets and collections (you need invoice due dates), but it
diverges from the ledger in two ways found here.

### Defect 3 — intercompany invoices counted (FIXED)

Breakdown of our AR at 18 Mar 2026:

| Journal | Open AR |
|---------|---------|
| **01- Inter Company Sales (56)** | **13,511,700.57** |
| 01- HORECA Invoices (19) | 9,245,107.14 |
| 01- Opening Balance (1) | 161,688.13 |
| 01- FOC (52) | 126.21 |
| **Total** | **22,918,622.05** |

**59% of reported receivables were one group company billing another.** Consolidated
across all 10 companies that is not money owed by anyone outside the group, and the
finance team's own reporting excludes it via the "P & L Without Inter Company"
journal group. Effect on the ledger side is the same size:

| Odoo Receivables, 18 Mar 2026 | Amount |
|---|---|
| All journals | 25,275,342.76 |
| Excluding intercompany (56, 57) | **11,762,424.19** |

**Fix:** new `_excluded_journal_ids()` reads `account.journal.group.excluded_journal_ids`
and `_ar_ap_aggregate` filters with `journal_id != ALL(...)`. Read from configuration,
not hardcoded, so the dashboard follows whatever finance sets up. Applies to both AR
and AP.

Note: defining intercompany by *counterparty partner* instead gives 13,741,755.36
(a 230,054.79 difference). Journal-based was chosen because it reproduces Odoo.

### Defect 4 — residual is read as of today, not as of the report date (OPEN)

The query filters on `payment_state` and sums `amount_residual` — both of which
reflect **today's** state, not the report date's. Consequences:

- An invoice open on 18 Mar but fully paid by September has `payment_state = 'paid'`
  today and is **excluded entirely**, though it *was* receivable on 18 Mar.
- An invoice since partially paid contributes its *current* residual, not the larger
  amount outstanding on 18 Mar.

Both understate any historical date. Measured:

```sql
SELECT SUM(apr.amount)
FROM account_partial_reconcile apr
JOIN account_move_line dl ON dl.id = apr.debit_move_id
JOIN account_move_line cl ON cl.id = apr.credit_move_id
JOIN account_account aa ON aa.id = dl.account_id
WHERE aa.account_type='asset_receivable' AND aa.non_trade = false
  AND dl.date <= '2026-03-18' AND cl.date > '2026-03-18';
-- 17,033,542.52
```

AED 17.03m of payments were matched *after* 18 Mar against invoices dated on or
before it. The net effect on the total is **AED 2,355,502.71** — precisely the gap
that remains after the intercompany fix.

This is a real defect and is **not yet fixed**. Today's figure (`as_of` = today) is
unaffected; only historical dates are.

### Verification

| 18 Mar 2026, all 10 companies | Amount |
|---|---|
| Dashboard before | 22,918,622.05 |
| Dashboard after intercompany fix | **9,406,921.48** |
| Odoo Balance Sheet | 11,762,424.19 |
| Remaining gap (defect 4) | 2,355,502.71 |

Aging buckets still sum exactly to the total (9,406,921.48), so internal
consistency is preserved.

---

## Part 3 — A trap that cost significant time

Screenshots used for comparison came from database **`gftuae_1_8_26`** (visible in
Odoo's top-right corner), not `gftuae_new`. That database stopped receiving entries
around 1 Aug 2026. Symptoms:

- Every date **before** the cutover matched us to the cent (10 Mar, 5 May).
- Every date **on or after** it returned an identical frozen figure — 1 Aug, 14 Aug
  and 19 Sep all showed exactly 2,430,367.06.
- 135 cash lines dated ≤ 1 Aug were *created* after 1 Aug in `gftuae_new`
  (net AED 421,039.05) and cannot exist in the older database.

**Always confirm both sides are on the same database before investigating a
discrepancy.** Compare on a date well before any cutover.

---

## Open items

1. **Defect 4** — rebase AR (and AP) on ledger balances as of the report date rather
   than current invoice residuals. Odoo's own Aged Receivable report does this using
   `account_move_line.date_maturity`, which would also let the aging buckets stay
   consistent with the total and fix the point-in-time error in one change.
2. **Intercompany exclusion is now applied to AR/AP only.** Sales, COGS and the
   Sales-by-Division chart still include intercompany activity, so revenue is
   overstated on the same basis. Needs a decision on whether the dashboard should be
   a consolidated (eliminated) view throughout.
3. The Balance Sheet's own Receivables figure goes sharply negative when scoped to
   company 1 alone, caused by customer payments posted to the ledger without being
   reconciled against invoices. That is a bookkeeping backlog, not a reporting bug,
   but it makes single-company ledger figures unreliable as a reference.
