# -*- coding: utf-8 -*-
import logging
import time
from datetime import date, datetime, timedelta

from dateutil.relativedelta import relativedelta

from odoo import http
from odoo.http import request

# TEMPORARY PROFILING - added for a one-off performance audit, to be removed
# once measurements are captured. Server-side logging only (_logger.info),
# never exposed in the JSON response returned to the dashboard.
_logger = logging.getLogger(__name__)


class FinanceDashboardController(http.Controller):
    """""
    
    Backend for the Finance Dashboard client action.

    NOTE ON sudo(): the reads below use sudo() so the dashboard works for any
    internal user regardless of their Accounting access rights. If that is too
    permissive for your case, remove sudo() and instead put users who should see
    this dashboard into the 'Accounting / Billing' or a dedicated custom group,
    then restrict the menu item to that group in views/finance_dashboard_views.xml.

    NOTE ON YOUR CHART OF ACCOUNTS: the account_type filters below
    ('expense_direct_cost' for COGS, 'expense' for opex) assume a fairly
    standard Odoo CoA. Double check these against Accounting > Configuration >
    Chart of Accounts and adjust the lists if your COA groups things differently.

    Supports a header toolbar in the UI: an "as of" date, a period
    (month / quarter / year) and a comparison basis (previous_period /
    previous_year), all passed as kwargs to get_dashboard_data.

    NOTE ON COMPANY SCOPE: the dashboard is scoped to whichever companies are
    currently active in the top-bar company switcher (the same selection used
    everywhere else in Odoo), not a dashboard-specific filter. The frontend
    sends that selection as `company_ids`; see _company_ids() below for how
    it's resolved and validated.

    NOTE ON AGGREGATION: the AR/AP, daily-sales, and category-sales helpers
    below aggregate in PostgreSQL (via read_group or a raw, read-only SQL
    query) rather than fetching every matching move/line into Python and
    summing there. This matters at real scale - e.g. one company in this
    database has 20M+ posted account_move_line rows and 400K+ posted
    invoices. The raw-SQL queries are read-only aggregates only (SELECT ...
    GROUP BY, no writes), parameterized (no string-built user input), and
    intentionally mirror the exact bucket/sign semantics the equivalent
    Python loop used, including the same day-bucket boundaries.
    """

    # ------------------------------------------------------------------ #
    # Helpers
    # ------------------------------------------------------------------ #

    def _company(self):
        return request.env.company

    def _company_ids(self, kwargs):
        """Resolve the company ids this request should be scoped to.

        Mirrors the top-bar company switcher's current selection (posted by
        the frontend as `company_ids`), validated through Odoo's own
        env.companies mechanism rather than trusted blindly - this reuses
        Odoo's built-in allowed-company access check instead of a hand-rolled
        one. Falls back to the user's default allowed companies if the
        frontend didn't post a selection (e.g. a direct RPC call in a test).
        """
        posted_ids = kwargs.get('company_ids')
        if posted_ids:
            env = request.env(context=dict(request.env.context, allowed_company_ids=posted_ids))
            company_ids = env.companies.ids
        else:
            company_ids = request.env.companies.ids
        return company_ids or [request.env.company.id]

    def _pct_change(self, current, previous):
        if not previous:
            return None
        return round((current - previous) / abs(previous) * 100, 1)

    # T-1 reporting policy. The dashboard deliberately lags one day: opened
    # today it reports through yesterday. Without this the KPIs move all day
    # as users enter and back-date work, so two people looking minutes apart
    # legitimately disagree.
    #
    # The lag is applied to the ACCOUNTING date (account_move_line.date),
    # never to create_date. That distinction is the whole point: a document
    # entered today but dated yesterday BELONGS to yesterday and is picked up
    # at the next refresh. Filtering on create_date would permanently exclude
    # it, which would silently understate closed periods.
    REPORTING_LAG_DAYS = 1

    def _reporting_cutoff(self):
        """Latest accounting date the dashboard may show."""
        return date.today() - timedelta(days=self.REPORTING_LAG_DAYS)

    def _parse_as_of(self, value):
        """Reporting date, never later than the T-1 cutoff.

        A requested date in the past is honoured unchanged; one reaching into
        today or the future is clamped. Without the clamp a user could pick
        today in the date filter and get a figure that keeps changing under
        them - exactly what the lag exists to prevent.
        """
        cutoff = self._reporting_cutoff()
        if value:
            try:
                return min(date.fromisoformat(value), cutoff)
            except ValueError:
                pass
        return cutoff

    def _reporting_vintage(self, company_ids):
        """When the reporting tables were last rebuilt, for auditability.

        Read from finance_dashboard_coverage, which 04_backfill_expense_and_derived.sql
        stamps on every refresh. Deliberately does NOT report covered_to: that
        column holds MAX(date) from the ledger, which this dataset pushes to
        2205-10-18 because of far-future-dated entries, so it cannot be used
        to describe how current the data is.
        """
        try:
            request.env.cr.execute(
                """SELECT MAX(last_refresh_at) AS refreshed_at,
                          bool_and(COALESCE(last_refresh_ok, false)) AS all_ok
                     FROM finance_dashboard_coverage
                    WHERE company_id = ANY(%s)""",
                (list(company_ids),),
            )
            return request.env.cr.dictfetchone() or {}
        except Exception:
            # Coverage is metadata, not a KPI - never fail the dashboard for it.
            return {}

    def _period_bounds(self, as_of, period):
        """Return (period_start, period_end) for the selected period, ending on as_of."""
        if period == 'quarter':
            q_start_month = ((as_of.month - 1) // 3) * 3 + 1
            start = date(as_of.year, q_start_month, 1)
        elif period == 'year':
            start = date(as_of.year, 1, 1)
        else:  # 'month' (default)
            start = as_of.replace(day=1)
        return start, as_of

    def _compare_bounds(self, period_start, period_end, compare):
        """Return (cmp_start, cmp_end): a range of the same length immediately
        before the period (previous_period), or the same range shifted back
        one year (previous_year)."""
        length = (period_end - period_start).days
        if compare == 'previous_year':
            cmp_start = period_start - relativedelta(years=1)
            cmp_end = period_end - relativedelta(years=1)
        else:  # 'previous_period' (default)
            cmp_end = period_start - timedelta(days=1)
            cmp_start = cmp_end - timedelta(days=length)
        return cmp_start, cmp_end

    def _sum_balance(self, domain, date_to):
        """Sum `balance` exactly the way Odoo's own financial reports do:
        scale every line by its company's conversion rate and round it to the
        display currency's precision *before* summing, rather than summing
        raw values. Mirrors the query in account_reports/models/
        account_report.py (_compute_formula_batch_with_engine_domain).
        account_move_line.balance is stored in the line's own company
        currency, so the rate is what keeps a multi-currency group from
        adding unlike units together.

        Fast path: when every company in scope already shares the display
        currency (true for all 10 companies here today), the conversion is
        mathematically a no-op, but the VALUES-joined query still costs
        real time on a large scan - measured at 27-28s per Working Capital
        call vs. 14.8s for a plain SUM(balance) on the identical domain.
        Skip the join in that case and only pay for it once a genuinely
        multi-currency company is added."""
        Aml = request.env['account.move.line'].sudo()
        companies = request.env['res.company'].sudo().search([])
        target = request.env.company.currency_id

        if all(c.currency_id == target for c in companies):
            res = Aml.read_group(domain, ['balance:sum'], [])
            return res[0]['balance'] or 0.0 if res else 0.0

        tables, where_clause, where_params = Aml._where_calc(domain).get_sql()
        ct_rows, ct_params = [], []
        for company in companies:
            rate = 1.0 if company.currency_id == target else company.currency_id._convert(
                1.0, target, company, date_to, round=False)
            ct_rows.append('(%s, %s, %s)')
            ct_params += [company.id, rate, target.decimal_places]

        request.env.cr.execute(
            f"""
            SELECT COALESCE(SUM(ROUND(
                       (account_move_line.balance * ct.rate)::numeric, ct.precision)), 0.0)
            FROM {tables}
            JOIN (VALUES {', '.join(ct_rows)}) AS ct(company_id, rate, precision)
              ON ct.company_id = account_move_line.company_id
            WHERE {where_clause}
            """,
            ct_params + where_params,
        )
        return request.env.cr.fetchone()[0] or 0.0

    # ------------------------------------------------------------------ #
    # Summary layer (finance_dashboard_* tables)
    #
    # Every figure below comes from the pre-aggregated summary tables
    # rather than the ledger. Two rules, and they are not interchangeable:
    #
    #   FLOW columns (sales, cogs, opex, other_income) are daily totals -
    #   SUM them across the requested range.
    #
    #   SNAPSHOT columns are stored as daily DELTAS. A balance "as of" a
    #   date is the cumulative sum of deltas up to it, so they are summed
    #   from inception to date_to and never over a range. Summing a
    #   snapshot column across a range would double-count.
    # ------------------------------------------------------------------ #

    _FLOW_COLUMNS = ('sales', 'cogs', 'opex', 'other_income', 'depreciation')
    _SNAPSHOT_COLUMNS = (
        'cash_bank_delta', 'ar_delta', 'ap_delta', 'ar_ic_delta', 'ap_ic_delta',
        'other_current_assets_delta', 'other_current_liabilities_delta',
    )

    def _prefetch_summary(self, company_ids, ranges, snap_dates):
        """Fetch every flow and snapshot figure the request needs in TWO
        queries instead of one per measure.

        The database is remote, so each round trip costs ~60-70ms
        regardless of how trivial the query is - measured: a flow query
        executes in 0.5ms but the controller sees 70ms. With ~31 separate
        reads that was ~2.2s of the request spent purely waiting on the
        network. Batching collapses it.

        `ranges`    : {name: (date_from, date_to)} for flow columns
        `snap_dates`: {name: date} for snapshot (cumulative) columns
        Results land in self._summary_cache for _summary_flow /
        _summary_snapshot to read.
        """
        cache = {}

        if ranges:
            sel, params = [], {'companies': list(company_ids)}
            for rname, (dfrom, dto) in ranges.items():
                params[f'{rname}_f'] = dfrom
                params[f'{rname}_t'] = dto
                for col in self._FLOW_COLUMNS:
                    sel.append(
                        f"COALESCE(SUM(CASE WHEN date BETWEEN %({rname}_f)s AND %({rname}_t)s "
                        f"THEN {col} ELSE 0 END), 0) AS {col}__{rname}"
                    )
            bounds = list(ranges.values())
            params['lo'] = min(b[0] for b in bounds)
            params['hi'] = max(b[1] for b in bounds)
            request.env.cr.execute(
                f"""SELECT {', '.join(sel)} FROM finance_dashboard_daily
                    WHERE company_id = ANY(%(companies)s)
                      AND date BETWEEN %(lo)s AND %(hi)s""",
                params,
            )
            row = request.env.cr.dictfetchone() or {}
            for key, val in row.items():
                col, rname = key.split('__')
                cache[('flow', col, rname)] = float(val or 0.0)

        if snap_dates:
            sel, params = [], {'companies': list(company_ids)}
            for dname, dto in snap_dates.items():
                params[f'{dname}_d'] = dto
                for col in self._SNAPSHOT_COLUMNS:
                    sel.append(
                        f"COALESCE(SUM(CASE WHEN date <= %({dname}_d)s "
                        f"THEN {col} ELSE 0 END), 0) AS {col}__{dname}"
                    )
            params['hi'] = max(snap_dates.values())
            request.env.cr.execute(
                f"""SELECT {', '.join(sel)} FROM finance_dashboard_daily
                    WHERE company_id = ANY(%(companies)s) AND date <= %(hi)s""",
                params,
            )
            row = request.env.cr.dictfetchone() or {}
            for key, val in row.items():
                col, dname = key.split('__')
                cache[('snap', col, dname)] = float(val or 0.0)

        self._summary_cache = cache

    def _summary_flow(self, column, range_name):
        """A flow measure for a named range, from the prefetched batch."""
        if column not in self._FLOW_COLUMNS:
            raise ValueError("not a flow column: %s" % column)
        return self._summary_cache[('flow', column, range_name)]

    def _summary_snapshot(self, column, date_name):
        """A snapshot (cumulative) measure at a named as-of date, from the
        prefetched batch."""
        if column not in self._SNAPSHOT_COLUMNS:
            raise ValueError("not a snapshot column: %s" % column)
        return self._summary_cache[('snap', column, date_name)]

    def _excluded_journal_ids(self):
        """Journals to count for AR/AP, after removing whatever journal
        groups exclude (here, the "P & L Without Inter Company" group,
        which strips the intercompany sales/purchase journals). An
        intercompany invoice is one group company billing another:
        consolidated across all 10 companies it is not money owed by
        anyone outside the group, so counting it overstates AR/AP by
        the intercompany amount (measured at AED 13.5m of AR on
        2026-03-18).

        Deliberately NOT applied as `journal_id NOT IN (...)` /
        `!= ALL(...)` on the main totals query - neither can use
        idx_am_fd_company_type_state_date (company_id, move_type, state,
        invoice_date) the way the existing filter-free query does.
        Measured: unfiltered query 4.6s; same query with
        `journal_id != ALL(2 ids)` still running after 4+ minutes - that
        regression is what took the dashboard down. `_ar_ap_aggregate`
        instead runs the fast unfiltered query and a second, separately
        fast query scoped to just these (few, highly selective) journals
        via `= ANY(...)`, then subtracts in Python - same result, no
        index regression."""
        return request.env['account.journal.group'].sudo().search([]) \
            .mapped('excluded_journal_ids').ids

    def _account_balance(self, account_ids, date_to, company_ids, date_from=None):
        if not account_ids:
            return 0.0
        domain = [
            ('account_id', 'in', account_ids),
            ('parent_state', '=', 'posted'),
            ('company_id', 'in', company_ids),
            ('date', '<=', date_to),
        ]
        if date_from:
            domain.append(('date', '>=', date_from))
        return self._sum_balance(domain, date_to)

    def _account_type_balance(self, account_types, date_to, company_ids):
        """Point-in-time GL balance (as of date_to) for accounts of the
        given account_type(s) - used for Working Capital's non-AR/AP
        current asset/liability components (inventory/stock valuation,
        prepayments, staff advances, accrued liabilities, etc.). Unlike
        Total Receivables/Payables, these aren't invoice-residual-based -
        there's no equivalent "open document" concept for them - so they're
        read directly from the ledger, the same way Cash & Bank already is.
        Returns Odoo's raw debit-minus-credit balance: positive for a
        healthy asset_current balance, negative for a healthy
        liability_current balance (callers apply abs() where a liability
        magnitude is needed, matching how Payables is already handled).

        Filters on a resolved account_id list rather than
        ('account_id.account_type', 'in', ...) directly: that related-field
        domain forces a join against account_account for every candidate
        line, which the planner can't push into
        idx_aml_fd_balance_by_account (company_id, account_id, date) -
        measured at 32s for a single asset_current call on this data.
        Resolving to account_id first (same approach already used for
        Cash & Bank) lets it hit that index: 14.8s measured, and the
        account_type -> account_ids lookup itself is a trivial metadata
        query."""
        account_ids = request.env['account.account'].sudo().search([
            ('account_type', 'in', account_types),
        ]).ids
        if not account_ids:
            return 0.0
        domain = [
            ('account_id', 'in', account_ids),
            ('parent_state', '=', 'posted'),
            ('company_id', 'in', company_ids),
            ('date', '<=', date_to),
        ]
        return self._sum_balance(domain, date_to)

    def _invoice_total(self, move_types, date_from, date_to, company_ids, field='amount_untaxed_signed'):
        domain = [
            ('move_type', 'in', move_types),
            ('state', '=', 'posted'),
            ('company_id', 'in', company_ids),
            ('invoice_date', '>=', date_from),
            ('invoice_date', '<=', date_to),
        ]
        res = request.env['account.move'].sudo().read_group(domain, [f'{field}:sum'], [])
        return res[0][field] or 0.0 if res else 0.0

    def _expense_total(self, date_from, date_to, account_types, company_ids):
        domain = [
            ('account_id.account_type', 'in', account_types),
            ('parent_state', '=', 'posted'),
            ('company_id', 'in', company_ids),
            ('date', '>=', date_from),
            ('date', '<=', date_to),
        ]
        res = request.env['account.move.line'].sudo().read_group(domain, ['balance:sum'], [])
        return res[0]['balance'] or 0.0 if res else 0.0

    def _income_total(self, date_from, date_to, account_types, company_ids):
        """Like _expense_total, but for credit-normal income accounts:
        their GL balance is negative when there's real income, so flip it."""
        domain = [
            ('account_id.account_type', 'in', account_types),
            ('parent_state', '=', 'posted'),
            ('company_id', 'in', company_ids),
            ('date', '>=', date_from),
            ('date', '<=', date_to),
        ]
        res = request.env['account.move.line'].sudo().read_group(domain, ['balance:sum'], [])
        return -(res[0]['balance'] or 0.0) if res else 0.0

    def _daily_sales_map(self, date_from, date_to, company_ids):
        """Daily sales totals for the trend chart, from the summary layer.
        One row per (company, date) already, so this is a small grouped read
        rather than an aggregate over every posted invoice."""
        cr = request.env.cr
        cr.execute(
            """
            SELECT date, COALESCE(SUM(sales), 0)
            FROM finance_dashboard_daily
            WHERE company_id = ANY(%(company_ids)s)
              AND date >= %(date_from)s AND date <= %(date_to)s
            GROUP BY date
            """,
            {'company_ids': list(company_ids), 'date_from': date_from, 'date_to': date_to},
        )
        return {row[0]: float(row[1] or 0.0) for row in cr.fetchall()}

    def _sum_range(self, daily_map, date_from, date_to):
        total = 0.0
        d = date_from
        while d <= date_to:
            total += daily_map.get(d, 0.0)
            d += timedelta(days=1)
        return total

    def _arap_batch(self, period_end, cmp_end, company_ids):
        """All AR/AP aging buckets (both sides, both as-of dates) in ONE
        query, and both top-5 rankings in ONE more. Same rationale as
        _prefetch_summary: the remote database costs ~60-70ms per round
        trip, so four bucket reads and two ranking reads were mostly spent
        waiting rather than working."""
        cr = request.env.cr
        params = {'companies': list(company_ids), 'pe': period_end, 'ce': cmp_end}
        age_pe = "(%(pe)s::date - COALESCE(date_maturity, date))"
        age_ce = "(%(ce)s::date - COALESCE(date_maturity, date))"
        bands = [('cur', '<= 0'), ('b1', 'BETWEEN 1 AND 30'), ('b2', 'BETWEEN 31 AND 60'),
                 ('b3', 'BETWEEN 61 AND 90'), ('b4', '> 90')]
        sel = []
        for side, col in (('ar', 'ar_amount'), ('ap', 'ap_amount')):
            for dname, age, dcol in (('period', age_pe, '%(pe)s'), ('cmp', age_ce, '%(ce)s')):
                for band, cond in bands:
                    sel.append(
                        f"COALESCE(SUM(CASE WHEN date <= {dcol} AND {age} {cond} "
                        f"THEN {col} ELSE 0 END), 0) AS {side}_{dname}_{band}"
                    )
        cr.execute(
            f"""SELECT {', '.join(sel)} FROM finance_dashboard_aging_daily
                WHERE company_id = ANY(%(companies)s)
                  AND date <= GREATEST(%(pe)s::date, %(ce)s::date)""",
            params,
        )
        buckets = cr.dictfetchone() or {}

        # Both rankings in one pass over the partner-level table.
        cr.execute(
            f"""
            SELECT side, partner_id, amt, days FROM (
              SELECT 'ar' AS side, partner_id,
                     SUM(ar_amount) AS amt, MAX({age_pe}) AS days,
                     ROW_NUMBER() OVER (ORDER BY SUM(ar_amount) DESC) AS rn
              FROM finance_dashboard_arap_daily
              WHERE company_id = ANY(%(companies)s) AND date <= %(pe)s
                AND NOT is_intercompany AND partner_id IS NOT NULL AND {age_pe} > 0
              GROUP BY partner_id HAVING SUM(ar_amount) > 0
              UNION ALL
              SELECT 'ap', partner_id,
                     -SUM(ap_amount), MAX({age_pe}),
                     ROW_NUMBER() OVER (ORDER BY -SUM(ap_amount) DESC)
              FROM finance_dashboard_arap_daily
              WHERE company_id = ANY(%(companies)s) AND date <= %(pe)s
                AND NOT is_intercompany AND partner_id IS NOT NULL AND {age_pe} > 0
              GROUP BY partner_id HAVING -SUM(ap_amount) > 0
            ) x WHERE rn <= 5
            """,
            params,
        )
        top_rows = cr.fetchall()
        names = {}
        if top_rows:
            for pr in request.env['res.partner'].sudo().browse(list({r[1] for r in top_rows})):
                names[pr.id] = pr.name
        tops = {'ar': [], 'ap': []}
        for side, pid, amt, days in top_rows:
            tops[side].append({'name': names.get(pid, 'Unknown'),
                               'amount': round(float(amt or 0), 2), 'days': int(days or 0)})

        out = {}
        for side in ('ar', 'ap'):
            sign = 1 if side == 'ar' else -1
            for dname in ('period', 'cmp'):
                total = sign * (
                    self._summary_snapshot(f'{side}_delta', dname)
                    - self._summary_snapshot(f'{side}_ic_delta', dname)
                )
                out[(side, dname)] = {
                    'total': total,
                    'buckets': {
                        'current': sign * float(buckets[f'{side}_{dname}_cur'] or 0.0),
                        '1-30':    sign * float(buckets[f'{side}_{dname}_b1'] or 0.0),
                        '31-60':   sign * float(buckets[f'{side}_{dname}_b2'] or 0.0),
                        '61-90':   sign * float(buckets[f'{side}_{dname}_b3'] or 0.0),
                        '90+':     sign * float(buckets[f'{side}_{dname}_b4'] or 0.0),
                    },
                    'top': tops[side] if dname == 'period' else [],
                }
        return out

    def _ar_ap_aggregate(self, side, date_to, date_name, company_ids, include_top=True):
        """AR/AP totals, aging buckets and top-5 overdue partners, read from
        the summary layer rather than the ledger.

        Basis (verified against Odoo's Balance Sheet on 2026-03-18, all 10
        companies): general-ledger balances on account_type
        asset_receivable / liability_payable with non_trade = false,
        excluding the intercompany journals. That reproduces Odoo exactly -
        11,762,424.19 for AR and -4,740,442.28 for AP. The previous
        invoice-residual basis could not: it read today's residual rather
        than the residual as of the report date, had no notion of
        non_trade, and summed unsigned residuals so credit notes added
        instead of netting down.

        `side` is 'ar' or 'ap'. AP is returned negated, matching Odoo's
        '-sum' subformula on its Payables line, so it can be displayed
        directly without abs().

        Aging cannot be pre-bucketed - a line's bucket depends on
        as_of - date_maturity - so buckets are computed at read time from
        finance_dashboard_arap_daily. Note these are ledger balances, so
        buckets can legitimately be negative where payments land against a
        maturity date.
        """
        if side not in ('ar', 'ap'):
            raise ValueError("side must be 'ar' or 'ap'")
        cr = request.env.cr
        sign = 1 if side == 'ar' else -1
        amount_col = 'ar_amount' if side == 'ar' else 'ap_amount'

        total = sign * (
            self._summary_snapshot(f'{side}_delta', date_name)
            - self._summary_snapshot(f'{side}_ic_delta', date_name)
        )

        age = "(%(date_to)s::date - COALESCE(date_maturity, date))"
        params = {'date_to': date_to, 'company_ids': list(company_ids)}
        cr.execute(
            f"""
            SELECT
                COALESCE(SUM(CASE WHEN {age} <= 0            THEN {amount_col} ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN {age} BETWEEN 1 AND 30  THEN {amount_col} ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN {age} BETWEEN 31 AND 60 THEN {amount_col} ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN {age} BETWEEN 61 AND 90 THEN {amount_col} ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN {age} > 90            THEN {amount_col} ELSE 0 END), 0)
            FROM finance_dashboard_aging_daily
            WHERE company_id = ANY(%(company_ids)s)
              AND date <= %(date_to)s
            """,
            params,
        )
        b_current, b_1_30, b_31_60, b_61_90, b_90_plus = [
            sign * float(v or 0.0) for v in cr.fetchone()
        ]

        top = []
        if include_top:
            cr.execute(
                f"""
                SELECT partner_id,
                       {sign} * SUM({amount_col}) AS amt,
                       MAX({age}) AS days
                FROM finance_dashboard_arap_daily
                WHERE company_id = ANY(%(company_ids)s)
                  AND date <= %(date_to)s
                  AND NOT is_intercompany
                  AND partner_id IS NOT NULL
                  AND {age} > 0
                GROUP BY partner_id
                HAVING {sign} * SUM({amount_col}) > 0
                ORDER BY amt DESC
                LIMIT 5
                """,
                params,
            )
            top_rows = cr.fetchall()
            names = {}
            if top_rows:
                for p in request.env['res.partner'].sudo().browse([r[0] for r in top_rows]):
                    names[p.id] = p.name
            top = [
                {'name': names.get(pid, 'Unknown'), 'amount': round(float(amt or 0), 2), 'days': int(days or 0)}
                for pid, amt, days in top_rows
            ]

        return {
            'total': total,
            'buckets': {
                'current': b_current,
                '1-30': b_1_30,
                '31-60': b_31_60,
                '61-90': b_61_90,
                '90+': b_90_plus,
            },
            'top': top,
        }

    # ------------------------------------------------------------------ #
    # Main endpoint
    # ------------------------------------------------------------------ #

    @http.route('/finance_dashboard/data', type='json', auth='user')
    def get_dashboard_data(self, **kwargs):
        # TEMPORARY PROFILING (see module-level _logger note) - remove
        # t_request_start, timings, and _timed() along with every _timed(...)
        # wrapper once measurements are captured.
        t_request_start = time.perf_counter()
        timings = []

        def _timed(label, func, *args, **kwargs):
            t0 = time.perf_counter()
            result = func(*args, **kwargs)
            timings.append((label, time.perf_counter() - t0))
            return result

        company_ids = self._company_ids(kwargs)

        as_of = self._parse_as_of(kwargs.get('as_of'))
        period = kwargs.get('period') or 'month'
        compare = kwargs.get('compare') or 'previous_period'
        # "Today's Sales" tracks the selected as_of date, not the system
        # clock - it's a single-day figure distinct from the [Period] Sales
        # KPI below (which already correctly covers the whole MTD/QTD/YTD
        # range). date.today() was previously used here unconditionally,
        # ignoring the dashboard's own date filter entirely.
        today = as_of

        period_start, period_end = self._period_bounds(as_of, period)
        cmp_start, cmp_end = self._compare_bounds(period_start, period_end, compare)
        period_label = {'month': 'MTD', 'quarter': 'QTD', 'year': 'YTD'}.get(period, 'MTD')
        period_name = {'month': 'This Month', 'quarter': 'This Quarter', 'year': 'This Year'}.get(period, 'This Month')
        compare_label = 'Last Year' if compare == 'previous_year' else 'Last Month'

        # "Today" mapped onto the comparison range, so Today's Sales compares
        # like for like instead of one day against a whole period.
        cmp_today = cmp_start + (today - period_start) if period_start <= today <= period_end else None

        # Single batched fetch for every flow and snapshot figure below.
        _t0 = time.perf_counter()
        self._prefetch_summary(
            company_ids,
            ranges={
                'today': (today, today),
                'period': (period_start, period_end),
                'cmp': (cmp_start, cmp_end),
                'cmptoday': (cmp_today, cmp_today) if cmp_today else (cmp_start, cmp_start),
            },
            snap_dates={'period': period_end, 'cmp': cmp_end},
        )
        timings.append(('prefetch_summary', time.perf_counter() - _t0))

        # ---- Cash & Bank Balance ----
        # Matches Odoo's own Balance Sheet "Bank and Cash Accounts" line
        # (account_report_expression id 53: account_id.account_type =
        # 'asset_cash'), not a journal-derived account list - a journal's
        # default_account_id can miss accounts that no journal points to
        # (e.g. this DB's "Petty Cash - HR" account, id 3001/code 101211,
        # which is asset_cash-typed but isn't any journal's default
        # account). No company filter here: in this DB every asset_cash
        # account is owned by the parent company, shared across all
        # sub-companies' journals - company scoping is applied below via
        # each move line's own company_id, not the account's owner.
        cash_bank_now = _timed('cash_snapshot', self._summary_snapshot, 'cash_bank_delta', 'period')
        cash_bank_cmp = _timed('cash_snapshot_cmp', self._summary_snapshot, 'cash_bank_delta', 'cmp')

        # ---- Sales (Today literal / selected period) ----
        today_sales = _timed('sales_today', self._summary_flow, 'sales', 'today')
        period_sales = _timed('sales_period', self._summary_flow, 'sales', 'period')
        cmp_sales = _timed('sales_cmp', self._summary_flow, 'sales', 'cmp')

        # "Today" mapped onto the comparison range, so Today's Sales has a
        # like-for-like comparison instead of a single day vs. a whole period.
        cmp_today_sales = (
            _timed('sales_cmp_today', self._summary_flow, 'sales', 'cmptoday')
            if cmp_today else 0.0
        )

        # ---- COGS / Gross Profit ----
        period_cogs = _timed('cogs_period', self._summary_flow, 'cogs', 'period')
        cmp_cogs = _timed('cogs_cmp', self._summary_flow, 'cogs', 'cmp')
        gross_profit = period_sales - period_cogs
        gross_profit_pct = round((gross_profit / period_sales) * 100, 1) if period_sales else 0.0
        cmp_gross_profit = cmp_sales - cmp_cogs
        cmp_gross_profit_pct = round((cmp_gross_profit / cmp_sales) * 100, 1) if cmp_sales else 0.0

        # ---- Operating Expenses, Other Income & Net Profit ----
        period_opex = _timed('opex_period', self._summary_flow, 'opex', 'period')
        cmp_opex = _timed('opex_cmp', self._summary_flow, 'opex', 'cmp')
        period_other_income = _timed('other_income_period', self._summary_flow, 'other_income', 'period')
        cmp_other_income = _timed('other_income_cmp', self._summary_flow, 'other_income', 'cmp')
        net_profit = gross_profit - period_opex + period_other_income
        cmp_net_profit = cmp_gross_profit - cmp_opex + cmp_other_income

        # ---- AR / AP (open invoices/bills, as of period_end and comparison end) ----
        _arap = _timed('arap_batch', self._arap_batch, period_end, cmp_end, company_ids)
        ar_summary = _arap[('ar', 'period')]
        ap_summary = _arap[('ap', 'period')]
        total_ar = ar_summary['total']
        total_ap = ap_summary['total']

        # include_top=False: cmp_ar_summary/cmp_ap_summary only ever read
        # ['total'] and (for AR) ['buckets']['90+'] downstream - confirmed
        # by exhaustive trace, ['top'] is never referenced for either.
        cmp_ar_summary = _arap[('ar', 'cmp')]
        cmp_ap_summary = _arap[('ap', 'cmp')]
        cmp_total_ar = cmp_ar_summary['total']
        cmp_total_ap = cmp_ap_summary['total']
        cmp_90_plus = cmp_ar_summary['buckets']['90+']

        # ---- Aging of Receivables + Top overdue customers ----
        buckets = ar_summary['buckets']
        ar_total = sum(buckets.values()) or 1.0
        aging = [
            {'range': k, 'amount': round(v, 2), 'pct': round(v / ar_total * 100, 1)}
            for k, v in buckets.items()
        ]
        top_customers = ar_summary['top']

        # ---- Top overdue suppliers ----
        top_suppliers = ap_summary['top']

        # ---- Working Capital (standard: Current Assets - Current Liabilities) ----
        # Was previously a simplification (Cash + AR - AP only), which
        # silently excluded every other current asset/liability - for this
        # business, dominated by inventory (Stock Valuation / Goods
        # Delivered accounts under asset_current), worth ~4.7M and the
        # single largest account category in the database by posted-line
        # volume. AR/AP still use the invoice-residual figures already
        # computed above (proven, via direct customer-level tracing, to be
        # immune to the raw-GL distortion from unreconciled payments this
        # project found) - only the *other* current assets/liabilities
        # (inventory, prepayments, staff advances, accrued liabilities,
        # etc.) are added from the raw ledger, since they have no
        # equivalent "open invoice" concept to read instead.
        other_current_assets = _timed('other_current_assets', self._summary_snapshot, 'other_current_assets_delta', 'period')
        cmp_other_current_assets = _timed('other_current_assets_cmp', self._summary_snapshot, 'other_current_assets_delta', 'cmp')
        other_current_liabilities = _timed('other_current_liabilities', self._summary_snapshot, 'other_current_liabilities_delta', 'period')
        cmp_other_current_liabilities = _timed('other_current_liabilities_cmp', self._summary_snapshot, 'other_current_liabilities_delta', 'cmp')

        # Sign convention: both _delta columns store the raw SUM(balance).
        # Odoo's Balance Sheet renders Current Liabilities with subformula
        # `-sum` (report line 61), so negating the stored balance gives the
        # figure Odoo displays. `abs()` was wrong here: it is only equivalent
        # while the balance is credit-heavy, and company 1's is debit-heavy
        # (it holds the mirror leg of the subsidiaries' intercompany
        # positions), where abs() forced a subtraction the ledger does not
        # support - measured error AED 5,606,079.72 for company 1 and
        # 4,966,411.97 consolidated at 2026-05-13.
        current_liabilities = -other_current_liabilities
        cmp_current_liabilities = -cmp_other_current_liabilities

        working_capital = (
            cash_bank_now + total_ar + other_current_assets
            - total_ap - current_liabilities
        )
        cmp_working_capital = (
            cash_bank_cmp + cmp_total_ar + cmp_other_current_assets
            - cmp_total_ap - cmp_current_liabilities
        )

        # ---- Sales trend: bucketed across the selected period vs comparison ----
        # Daily buckets for short periods (month), coarser buckets for
        # quarter/year so we don't issue hundreds of queries.
        num_days = (period_end - period_start).days + 1
        if num_days <= 31:
            step, label_fmt = 1, '%d %b'
        elif num_days <= 120:
            step, label_fmt = 7, '%d %b'
        else:
            step, label_fmt = 30, '%b %Y'

        actual_daily = _timed('daily_sales_map_current', self._daily_sales_map, period_start, period_end, company_ids)
        previous_daily = _timed('daily_sales_map_cmp', self._daily_sales_map, cmp_start, cmp_end, company_ids)

        labels, actual, previous = [], [], []
        i = 0
        while i < num_days:
            bucket_len = min(step, num_days - i) - 1
            d_start = period_start + timedelta(days=i)
            d_end = d_start + timedelta(days=bucket_len)
            c_start = cmp_start + timedelta(days=i)
            c_end = c_start + timedelta(days=bucket_len)
            labels.append(d_start.strftime(label_fmt))
            actual.append(round(self._sum_range(actual_daily, d_start, d_end), 2))
            previous.append(round(self._sum_range(previous_daily, c_start, c_end), 2))
            i += step

        # ---- Sales by division (company) - selected period ----
        # Served straight from finance_dashboard_daily, which is already
        # grouped by (company_id, date): each division is one slice, never
        # summed together. The old rollup table plus its live-SQL fallback
        # and coverage tracking are gone - the summary layer covers all
        # dates, so there is nothing to fall back to.
        _t0 = time.perf_counter()
        cr = request.env.cr
        cr.execute(
            """
            SELECT company_id, COALESCE(SUM(sales), 0)
            FROM finance_dashboard_daily
            WHERE company_id = ANY(%s) AND date >= %s AND date <= %s
            GROUP BY company_id
            HAVING COALESCE(SUM(sales), 0) <> 0
            """,
            [list(company_ids), period_start, period_end],
        )
        division_totals = {row[0]: float(row[1] or 0.0) for row in cr.fetchall()}
        timings.append(('category_sales_summary', time.perf_counter() - _t0))

        _t0 = time.perf_counter()
        # Division (company) names for whichever companies actually had
        # matching sales in this period - a selected company with zero
        # matching sales simply doesn't appear as a slice (same "no
        # fallback to a default" behavior the original per-category
        # breakdown had for periods/companies with nothing to show).
        _divisions = request.env['res.company'].sudo().browse(list(division_totals.keys()))
        category_sales = sorted(
            ({'name': c.name, 'amount': round(division_totals[c.id], 2)} for c in _divisions),
            key=lambda r: r['amount'], reverse=True,
        )
        timings.append(('category_sales_categ_lookup', time.perf_counter() - _t0))
        _category_sales_product_count = len(division_totals)

        # ---- Expenses vs comparison period, by account ----
        # Both periods resolved in one pass over the summary table.
        _t0 = time.perf_counter()
        cr.execute(
            """
            SELECT account_id,
                   COALESCE(SUM(CASE WHEN date BETWEEN %(ps)s AND %(pe)s THEN amount ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN date BETWEEN %(cs)s AND %(ce)s THEN amount ELSE 0 END), 0)
            FROM finance_dashboard_expense_daily
            WHERE company_id = ANY(%(companies)s)
              AND (date BETWEEN %(ps)s AND %(pe)s OR date BETWEEN %(cs)s AND %(ce)s)
            GROUP BY account_id
            """,
            {'companies': list(company_ids), 'ps': period_start, 'pe': period_end,
             'cs': cmp_start, 'ce': cmp_end},
        )
        _exp_rows = cr.fetchall()
        timings.append(('expenses_table_summary', time.perf_counter() - _t0))

        _acc_names = {}
        if _exp_rows:
            for a in request.env['account.account'].sudo().browse([r[0] for r in _exp_rows]):
                _acc_names[a.id] = a.display_name
        expenses_table = []
        for acc_id, this_amt, cmp_amt in _exp_rows:
            this_amt = float(this_amt or 0.0)
            cmp_amt = float(cmp_amt or 0.0)
            if not this_amt and not cmp_amt:
                continue
            expenses_table.append({
                'name': _acc_names.get(acc_id, 'Unknown'),
                'this_month': round(this_amt, 2),
                'last_month': round(cmp_amt, 2),
                'variance': round(this_amt - cmp_amt, 2),
            })
        expenses_table.sort(key=lambda e: abs(e['this_month']), reverse=True)

        # TEMPORARY PROFILING - remove this whole block along with the
        # t_request_start/timings/_timed setup above and every _timed(...)
        # wrapper once measurements are captured.
        _total_time = time.perf_counter() - t_request_start
        _db_time = sum(t for _, t in timings)
        _python_overhead = _total_time - _db_time
        _logger.info(
            "finance_dashboard TIMING company_ids=%s as_of=%s period=%s compare=%s "
            "total=%.3fs db_total=%.3fs python_overhead=%.3fs category_sales_product_count=%s | %s",
            company_ids, as_of.isoformat(), period, compare,
            _total_time, _db_time, _python_overhead, _category_sales_product_count,
            " | ".join(f"{name}={elapsed:.3f}s" for name, elapsed in timings),
        )

        # Reporting vintage: what period this represents and when the tables
        # behind it were last rebuilt. Both are needed - back-dated entries can
        # still change yesterday's figures right up until the next refresh, so
        # the cutoff date alone does not identify the data.
        _vintage = self._reporting_vintage(company_ids)
        _refreshed_at = _vintage.get('refreshed_at')
        _refreshed_str = _refreshed_at.strftime('%Y-%m-%d %H:%M') if _refreshed_at else None
        _vintage_label = (
            f"Accounting data through {as_of.isoformat()}"
            + (f", reporting tables refreshed {_refreshed_str}" if _refreshed_str
               else ", reporting refresh time unknown")
        )

        return {
            'as_of': f"{as_of.strftime('%d %b %Y')} {datetime.now().strftime('%I:%M %p')}",
            'reporting_cutoff': as_of.isoformat(),
            'reporting_lag_days': self.REPORTING_LAG_DAYS,
            'reporting_refreshed_at': _refreshed_str,
            'reporting_refresh_ok': _vintage.get('all_ok'),
            'reporting_vintage': _vintage_label,
            'period': period,
            'period_label': period_label,
            'period_name': period_name,
            'compare': compare,
            'compare_label': compare_label,
            'company_ids': company_ids,
            'cash_bank_balance': round(cash_bank_now, 2),
            'cash_bank_change': self._pct_change(cash_bank_now, cash_bank_cmp),
            'today_sales': round(today_sales, 2),
            'today_sales_change': self._pct_change(today_sales, cmp_today_sales),
            'mtd_sales': round(period_sales, 2),
            'mtd_sales_change': self._pct_change(period_sales, cmp_sales),
            'gross_profit_pct': gross_profit_pct,
            'gross_profit_pct_change': round(gross_profit_pct - cmp_gross_profit_pct, 1),
            'net_profit': round(net_profit, 2),
            'net_profit_change': self._pct_change(net_profit, cmp_net_profit),
            'total_ar': round(total_ar, 2),
            'total_ar_change': self._pct_change(total_ar, cmp_total_ar),
            # Reported exactly as Odoo's Balance Sheet Payables line does
            # (its '-sum' subformula is already applied in _ar_ap_aggregate),
            # so this can legitimately be negative when the payable accounts
            # sit in a net debit position. No abs() - that would hide the sign.
            'total_ap': round(total_ap, 2),
            'total_ap_change': self._pct_change(total_ap, cmp_total_ap),
            'receivable_90_plus': round(buckets['90+'], 2),
            'receivable_90_plus_change': self._pct_change(buckets['90+'], cmp_90_plus),
            'total_expenses': round(period_opex, 2),
            'total_expenses_change': self._pct_change(period_opex, cmp_opex),
            'working_capital': round(working_capital, 2),
            'working_capital_change': self._pct_change(working_capital, cmp_working_capital),
            'aging': aging,
            'top_customers': top_customers,
            'top_suppliers': top_suppliers,
            'sales_trend': {'labels': labels, 'actual': actual, 'last_month': previous},
            'category_sales': category_sales,
            'category_sales_total': round(sum(c['amount'] for c in category_sales), 2),
            'expenses_table': expenses_table,
            'pnl': {
                'total_sales': round(period_sales, 2),
                'total_sales_change': self._pct_change(period_sales, cmp_sales),
                'cogs': round(period_cogs, 2),
                'cogs_change': self._pct_change(period_cogs, cmp_cogs),
                'gross_profit': round(gross_profit, 2),
                'gross_profit_change': self._pct_change(gross_profit, cmp_gross_profit),
                'gross_profit_pct': gross_profit_pct,
                'opex': round(period_opex, 2),
                'opex_change': self._pct_change(period_opex, cmp_opex),
                'other_income': round(period_other_income, 2),
                'other_income_change': self._pct_change(period_other_income, cmp_other_income),
                'net_profit': round(net_profit, 2),
                'net_profit_change': self._pct_change(net_profit, cmp_net_profit),
            },
        }
