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

    def _parse_as_of(self, value):
        if value:
            try:
                return date.fromisoformat(value)
            except ValueError:
                pass
        return date.today()

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
        res = request.env['account.move.line'].sudo().read_group(domain, ['balance:sum'], [])
        return res[0]['balance'] or 0.0 if res else 0.0

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

    def _daily_sales_map(self, move_types, date_from, date_to, company_ids, field='amount_untaxed_signed'):
        """Pre-aggregate posted invoice totals by exact calendar date, in
        PostgreSQL, so the sales-trend loop can sum arbitrary day-ranges in
        Python against a small (at most one row per day) dict instead of
        iterating every matching invoice. `field` is restricted to a fixed
        whitelist since it's interpolated into the SQL column list.
        """
        if field not in ('amount_untaxed_signed', 'amount_total_signed', 'amount_residual'):
            raise ValueError("Unsupported field for _daily_sales_map: %r" % (field,))
        cr = request.env.cr
        cr.execute(
            f"""
            SELECT invoice_date, SUM({field}) AS total
            FROM account_move
            WHERE move_type = ANY(%(move_types)s)
              AND state = 'posted'
              AND company_id = ANY(%(company_ids)s)
              AND invoice_date >= %(date_from)s
              AND invoice_date <= %(date_to)s
            GROUP BY invoice_date
            """,
            {
                'move_types': move_types,
                'company_ids': company_ids,
                'date_from': date_from,
                'date_to': date_to,
            },
        )
        return {row[0]: float(row[1] or 0.0) for row in cr.fetchall()}

    def _sum_range(self, daily_map, date_from, date_to):
        total = 0.0
        d = date_from
        while d <= date_to:
            total += daily_map.get(d, 0.0)
            d += timedelta(days=1)
        return total

    def _ar_ap_aggregate(self, move_types, date_to, company_ids, abs_for_top=False, include_top=True):
        """SQL-side replacement for fetching every open AR/AP move into
        Python and looping over it. Returns the same information the
        original per-move loop computed - total open amount (raw sum, not
        abs'd here; callers apply abs() at the same point the original code
        did, e.g. only on the final AP total, not per line - to preserve
        exact existing sign semantics), the four aging buckets using the
        exact same day-boundary rule as the original if/elif/elif/else
        chain (a not-yet-due or exactly-due move still falls in '0-30',
        matching current behavior), and the top-5 overdue (days > 0)
        partners by amount.

        `abs_for_top`: the original code used abs(amount_residual) when
        building the AP top-suppliers ranking specifically (but not for the
        AP total). Same behavior here.

        `include_top`: the top-5 query and its res.partner name lookup are
        a separate round-trip (confirmed via trace: comparison-period calls
        only ever read `total`/`buckets['90+']`, never `top`). Measured
        (odoo shell, live data, 3 company scopes): this skippable work costs
        ~0.49-0.59s per call, roughly matching or exceeding the totals+
        buckets query itself. Set False to skip it and return `top: []`.
        """
        cr = request.env.cr
        due_expr = "COALESCE(invoice_date_due, invoice_date)"
        base_where = """
            move_type = ANY(%(move_types)s) AND state = 'posted'
            AND payment_state = ANY(%(payment_states)s) AND company_id = ANY(%(company_ids)s)
            AND invoice_date <= %(date_to)s
        """
        params = {
            'move_types': move_types,
            'payment_states': ['not_paid', 'partial'],
            'company_ids': company_ids,
            'date_to': date_to,
        }

        cr.execute(
            f"""
            SELECT
                COALESCE(SUM(amount_residual), 0) AS total,
                COALESCE(SUM(CASE WHEN (%(date_to)s::date - {due_expr}) <= 30
                                   THEN amount_residual ELSE 0 END), 0) AS b_0_30,
                COALESCE(SUM(CASE WHEN (%(date_to)s::date - {due_expr}) BETWEEN 31 AND 60
                                   THEN amount_residual ELSE 0 END), 0) AS b_31_60,
                COALESCE(SUM(CASE WHEN (%(date_to)s::date - {due_expr}) BETWEEN 61 AND 90
                                   THEN amount_residual ELSE 0 END), 0) AS b_61_90,
                COALESCE(SUM(CASE WHEN (%(date_to)s::date - {due_expr}) > 90
                                   THEN amount_residual ELSE 0 END), 0) AS b_90_plus
            FROM account_move
            WHERE {base_where}
            """,
            params,
        )
        total, b_0_30, b_31_60, b_61_90, b_90_plus = cr.fetchone()

        top = []
        if include_top:
            amt_expr = "ABS(amount_residual)" if abs_for_top else "amount_residual"
            cr.execute(
                f"""
                SELECT partner_id, SUM({amt_expr}) AS amt,
                       MAX((%(date_to)s::date - {due_expr})) AS days
                FROM account_move
                WHERE {base_where}
                  AND (%(date_to)s::date - {due_expr}) > 0
                  AND partner_id IS NOT NULL
                GROUP BY partner_id
                ORDER BY amt DESC
                LIMIT 5
                """,
                params,
            )
            top_rows = cr.fetchall()
            partner_ids = [r[0] for r in top_rows]
            names = {}
            if partner_ids:
                for p in request.env['res.partner'].sudo().browse(partner_ids):
                    names[p.id] = p.name
            top = [
                {'name': names.get(pid, 'Unknown'), 'amount': round(float(amt or 0), 2), 'days': int(days or 0)}
                for pid, amt, days in top_rows
            ]

        return {
            'total': float(total or 0.0),
            'buckets': {
                '0-30': float(b_0_30 or 0.0),
                '31-60': float(b_31_60 or 0.0),
                '61-90': float(b_61_90 or 0.0),
                '90+': float(b_90_plus or 0.0),
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

        # ---- Cash & Bank Balance ----
        journals = request.env['account.journal'].sudo().search([
            ('type', 'in', ['bank', 'cash']), ('company_id', 'in', company_ids),
        ])
        cash_accounts = journals.mapped('default_account_id').ids
        cash_bank_now = _timed('account_balance_current', self._account_balance, cash_accounts, period_end, company_ids)
        cash_bank_cmp = _timed('account_balance_cmp', self._account_balance, cash_accounts, cmp_end, company_ids)

        # ---- Sales (Today literal / selected period) ----
        today_sales = _timed('invoice_total_today', self._invoice_total, ['out_invoice', 'out_refund'], today, today, company_ids)
        period_sales = _timed('invoice_total_period', self._invoice_total, ['out_invoice', 'out_refund'], period_start, period_end, company_ids)
        cmp_sales = _timed('invoice_total_cmp', self._invoice_total, ['out_invoice', 'out_refund'], cmp_start, cmp_end, company_ids)

        # "Today" mapped onto the comparison range, so Today's Sales has a
        # like-for-like comparison instead of a single day vs. a whole period.
        if period_start <= today <= period_end:
            cmp_today = cmp_start + (today - period_start)
            cmp_today_sales = _timed('invoice_total_cmp_today', self._invoice_total, ['out_invoice', 'out_refund'], cmp_today, cmp_today, company_ids)
        else:
            cmp_today_sales = 0.0

        # ---- COGS / Gross Profit ----
        period_cogs = _timed('expense_total_cogs_period', self._expense_total, period_start, period_end, ['expense_direct_cost'], company_ids)
        cmp_cogs = _timed('expense_total_cogs_cmp', self._expense_total, cmp_start, cmp_end, ['expense_direct_cost'], company_ids)
        gross_profit = period_sales - period_cogs
        gross_profit_pct = round((gross_profit / period_sales) * 100, 1) if period_sales else 0.0
        cmp_gross_profit = cmp_sales - cmp_cogs
        cmp_gross_profit_pct = round((cmp_gross_profit / cmp_sales) * 100, 1) if cmp_sales else 0.0

        # ---- Operating Expenses, Other Income & Net Profit ----
        period_opex = _timed('expense_total_opex_period', self._expense_total, period_start, period_end, ['expense'], company_ids)
        cmp_opex = _timed('expense_total_opex_cmp', self._expense_total, cmp_start, cmp_end, ['expense'], company_ids)
        period_other_income = _timed('income_total_period', self._income_total, period_start, period_end, ['income_other'], company_ids)
        cmp_other_income = _timed('income_total_cmp', self._income_total, cmp_start, cmp_end, ['income_other'], company_ids)
        net_profit = gross_profit - period_opex + period_other_income
        cmp_net_profit = cmp_gross_profit - cmp_opex + cmp_other_income

        # ---- AR / AP (open invoices/bills, as of period_end and comparison end) ----
        ar_summary = _timed('ar_aggregate_current', self._ar_ap_aggregate, ['out_invoice', 'out_refund'], period_end, company_ids)
        ap_summary = _timed('ap_aggregate_current', self._ar_ap_aggregate, ['in_invoice', 'in_refund'], period_end, company_ids, abs_for_top=True)
        total_ar = ar_summary['total']
        total_ap = ap_summary['total']

        # include_top=False: cmp_ar_summary/cmp_ap_summary only ever read
        # ['total'] and (for AR) ['buckets']['90+'] downstream - confirmed
        # by exhaustive trace, ['top'] is never referenced for either.
        cmp_ar_summary = _timed('ar_aggregate_cmp', self._ar_ap_aggregate, ['out_invoice', 'out_refund'], cmp_end, company_ids, include_top=False)
        cmp_ap_summary = _timed('ap_aggregate_cmp', self._ar_ap_aggregate, ['in_invoice', 'in_refund'], cmp_end, company_ids, include_top=False)
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

        # ---- Working Capital (simplified: Cash & Bank + AR - AP) ----
        working_capital = cash_bank_now + total_ar - abs(total_ap)
        cmp_working_capital = cash_bank_cmp + cmp_total_ar - abs(cmp_total_ap)

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

        actual_daily = _timed('daily_sales_map_current', self._daily_sales_map, ['out_invoice', 'out_refund'], period_start, period_end, company_ids)
        previous_daily = _timed('daily_sales_map_cmp', self._daily_sales_map, ['out_invoice', 'out_refund'], cmp_start, cmp_end, company_ids)

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

              # ---- Sales by product category (selected period) ----
        # Raw SQL with company_id filtered explicitly on BOTH account_move_line
        # and account_move: a read_group() with a move_id.move_type domain path
        # compiles to a LEFT JOIN where Postgres can't push company_id through
        # to the account_move side, causing a full-table scan of account_move
        # across every company (confirmed via EXPLAIN ANALYZE - ~47s of an
        # ~83s total for this one query, on HORECA). Filtering company_id
        # explicitly on both l and m lets the planner use an index on each side.
        _t0 = time.perf_counter()
        cr = request.env.cr
        cr.execute(
            """
            SELECT l.product_id, SUM(l.price_subtotal) AS total
            FROM account_move_line l
            JOIN (
                SELECT id FROM account_move
                WHERE company_id = ANY(%(company_ids)s) AND move_type = 'out_invoice' AND state = 'posted'
                  AND invoice_date >= %(period_start)s AND invoice_date <= %(period_end)s
            ) m ON m.id = l.move_id
            WHERE l.company_id = ANY(%(company_ids)s)
              AND l.parent_state = 'posted'
              AND l.product_id IS NOT NULL
              AND l.date >= %(period_start)s AND l.date <= %(period_end)s
            GROUP BY l.product_id
            """,
            {
                'company_ids': company_ids,
                'period_start': period_start,
                'period_end': period_end,
            },
        )
        product_totals = [{'product_id': row[0], 'price_subtotal': float(row[1] or 0.0)} for row in cr.fetchall()]
        timings.append(('category_sales_sql', time.perf_counter() - _t0))

        _t0 = time.perf_counter()
        product_ids = [r['product_id'] for r in product_totals]
        # Bulk raw-SQL category lookup, replacing a per-record ORM browse
        # loop over product.product.categ_id - that field is a non-stored
        # related field (product_tmpl_id.categ_id), so each access went
        # through the ORM's related-field resolution machinery rather than
        # a direct column read. Measured (odoo shell, live data, 3 company
        # scopes, cr.sql_log_count): ORM loop ~0.68-0.91s across 6 queries;
        # this single query ~0.07-0.08s across 1 query - same results
        # (verified via full dict equality), ~10-12x faster.
        categ_by_product = {}
        if product_ids:
            cr.execute(
                """
                SELECT pp.id, pc.name
                FROM product_product pp
                JOIN product_template pt ON pt.id = pp.product_tmpl_id
                LEFT JOIN product_category pc ON pc.id = pt.categ_id
                WHERE pp.id = ANY(%(product_ids)s)
                """,
                {'product_ids': product_ids},
            )
            categ_by_product = {row[0]: (row[1] or 'Uncategorized') for row in cr.fetchall()}
        cat_totals = {}
        for r in product_totals:
            cat = categ_by_product.get(r['product_id'], 'Uncategorized')
            cat_totals[cat] = cat_totals.get(cat, 0.0) + r['price_subtotal']
        category_sales = [
            {'name': k, 'amount': round(v, 2)}
            for k, v in sorted(cat_totals.items(), key=lambda x: x[1], reverse=True)
        ]
        timings.append(('category_sales_categ_lookup', time.perf_counter() - _t0))
        _category_sales_product_count = len(product_ids)

        # ---- Expenses vs comparison period, by account ----
        _t0 = time.perf_counter()
        exp_lines = request.env['account.move.line'].sudo().read_group(
            [('account_id.account_type', 'in', ['expense', 'expense_direct_cost']),
             ('parent_state', '=', 'posted'),
             ('company_id', 'in', company_ids),
             ('date', '>=', period_start), ('date', '<=', period_end)],
            ['balance:sum'], ['account_id'])
        timings.append(('expenses_table_current', time.perf_counter() - _t0))
        _t0 = time.perf_counter()
        cmp_exp_lines = request.env['account.move.line'].sudo().read_group(
            [('account_id.account_type', 'in', ['expense', 'expense_direct_cost']),
             ('parent_state', '=', 'posted'),
             ('company_id', 'in', company_ids),
             ('date', '>=', cmp_start), ('date', '<=', cmp_end)],
            ['balance:sum'], ['account_id'])
        timings.append(('expenses_table_cmp', time.perf_counter() - _t0))
        cmp_by_account = {r['account_id'][0]: r['balance'] for r in cmp_exp_lines if r['account_id']}
        expenses_table = []
        for r in exp_lines:
            if not r['account_id']:
                continue
            acc_id, acc_name = r['account_id']
            this_amt = r['balance'] or 0.0
            cmp_amt = cmp_by_account.get(acc_id, 0.0)
            expenses_table.append({
                'name': acc_name,
                'this_month': round(this_amt, 2),
                'last_month': round(cmp_amt, 2),
                'variance': round(this_amt - cmp_amt, 2),
            })

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

        return {
            'as_of': f"{as_of.strftime('%d %b %Y')} {datetime.now().strftime('%I:%M %p')}",
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
            'total_ap': round(abs(total_ap), 2),
            'total_ap_change': self._pct_change(abs(total_ap), abs(cmp_total_ap)),
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
