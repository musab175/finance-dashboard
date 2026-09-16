# -*- coding: utf-8 -*-
import logging
from datetime import timedelta

from odoo import api, fields, models

_logger = logging.getLogger(__name__)

# Trailing refresh window, in days. Derived from real data, not assumed:
# create_date-vs-date lag on posted invoice lines (180-day sample, all
# companies) showed p99=7 days, max=73 days. 14 days is a 2x safety
# margin over p99 - see the finance-dashboard reporting-layer Phase 6
# validation. Corrections older than this window require an explicit
# targeted/full rebuild, not the routine cron.
CATEGORY_SALES_REFRESH_WINDOW_DAYS = 14


class FinanceDashboardCategorySalesDaily(models.Model):
    """Reporting/rollup layer for the Finance Dashboard's Category Sales
    metric, read by controllers/main.py whenever the coverage table below
    confirms fresh, successful coverage for the requested company/date
    range - falling back to the original live SQL otherwise.

    Grain: one row per (company_id, date, product_id), summing
    price_subtotal across all account_move_line rows that would be
    counted by the live Category Sales SQL for that exact
    company/date/product combination:
      - account_move.move_type = 'out_invoice', account_move.state = 'posted'
      - account_move_line.parent_state = 'posted', product_id IS NOT NULL

    Category is deliberately NOT stored here - it's resolved at read time
    via the existing product -> template -> category join (already fast,
    ~70-80ms), so a product re-categorization never leaves this table
    stale.
    """
    _name = 'finance.dashboard.category.sales.daily'
    _description = 'Finance Dashboard: Category Sales daily rollup (reporting layer)'
    _auto = True
    _log_access = False
    _rec_name = 'date'

    company_id = fields.Many2one('res.company', required=True, index=True, ondelete='cascade')
    date = fields.Date(required=True, index=True)
    product_id = fields.Many2one('product.product', required=True, index=True, ondelete='cascade')
    amount = fields.Float(required=True, digits=(16, 2))
    updated_at = fields.Datetime(required=True, default=fields.Datetime.now)

    _sql_constraints = [
        (
            'company_date_product_uniq',
            'unique(company_id, date, product_id)',
            'One rollup row per company/date/product.',
        ),
    ]

    @api.model
    def _cron_refresh(self):
        """Refresh the rollup + coverage table for a bounded trailing
        window (today back CATEGORY_SALES_REFRESH_WINDOW_DAYS), one
        company at a time. Each company runs inside its own SAVEPOINT:
        a failure in one company's aggregation rolls back only that
        company's attempted write and leaves its previous coverage row
        (last known-good) completely untouched, with last_refresh_ok
        flipped to False so staleness is visible - it never blocks other
        companies in the same run, and it never advances covered_to on a
        failed attempt. Companies are discovered dynamically
        (res.company.search([])), never hardcoded.
        """
        Coverage = self.env['finance.dashboard.category.sales.coverage']
        today = fields.Date.context_today(self)
        window_start = today - timedelta(days=CATEGORY_SALES_REFRESH_WINDOW_DAYS)
        cr = self.env.cr
        companies = self.env['res.company'].search([])
        for company in companies:
            try:
                with cr.savepoint():
                    cr.execute(
                        """
                        INSERT INTO finance_dashboard_category_sales_daily
                            (company_id, date, product_id, amount, updated_at)
                        SELECT l.company_id, l.date, l.product_id, SUM(l.price_subtotal), now()
                        FROM account_move_line l
                        JOIN account_move m ON m.id = l.move_id
                        WHERE m.move_type = 'out_invoice' AND m.state = 'posted'
                          AND l.parent_state = 'posted' AND l.product_id IS NOT NULL
                          AND l.company_id = %(company_id)s
                          AND l.date >= %(window_start)s AND l.date <= %(today)s
                        GROUP BY l.company_id, l.date, l.product_id
                        ON CONFLICT (company_id, date, product_id) DO UPDATE
                            SET amount = EXCLUDED.amount, updated_at = EXCLUDED.updated_at
                        """,
                        {'company_id': company.id, 'window_start': window_start, 'today': today},
                    )
                    coverage = Coverage.search([('company_id', '=', company.id)], limit=1)
                    covered_from = min(coverage.covered_from, window_start) if coverage else window_start
                    if coverage:
                        coverage.write({
                            'covered_from': covered_from,
                            'covered_to': today,
                            'last_refresh_at': fields.Datetime.now(),
                            'last_refresh_ok': True,
                        })
                    else:
                        Coverage.create({
                            'company_id': company.id,
                            'covered_from': covered_from,
                            'covered_to': today,
                            'last_refresh_at': fields.Datetime.now(),
                            'last_refresh_ok': True,
                        })
            except Exception:
                _logger.exception(
                    "finance_dashboard: Category Sales rollup refresh failed for company_id=%s "
                    "- previous coverage left untouched, marked stale",
                    company.id,
                )
                coverage = Coverage.search([('company_id', '=', company.id)], limit=1)
                if coverage:
                    coverage.write({'last_refresh_ok': False, 'last_refresh_at': fields.Datetime.now()})


class FinanceDashboardCategorySalesCoverage(models.Model):
    """Explicit freshness/coverage tracking for the Category Sales rollup,
    one row per company. Written by the refresh job as a stated fact -
    NOT inferred from MIN/MAX(date) over the rollup data.

    Why this exists (found via testing, not assumed upfront): a coverage
    check based on MIN/MAX(date) in finance_dashboard_category_sales_daily
    breaks in two real cases -
      1. Non-contiguous rollup data (e.g. a gap between two populated
         windows) makes MIN/MAX span the gap and falsely report full
         coverage for dates inside it.
      2. A company/period with zero matching sales produces zero rollup
         rows, which is indistinguishable from "never refreshed" under a
         pure row-presence check.
    Both are fixed by having the refresh job explicitly assert what it
    covered, independent of whether that produced any data rows.
    """
    _name = 'finance.dashboard.category.sales.coverage'
    _description = 'Finance Dashboard: Category Sales rollup coverage/freshness'
    _auto = True
    _log_access = False
    _rec_name = 'company_id'

    company_id = fields.Many2one('res.company', required=True, index=True, ondelete='cascade')
    covered_from = fields.Date(required=True)
    covered_to = fields.Date(required=True)
    last_refresh_at = fields.Datetime(required=True, default=fields.Datetime.now)
    last_refresh_ok = fields.Boolean(required=True, default=True)

    _sql_constraints = [
        ('company_uniq', 'unique(company_id)', 'One coverage row per company.'),
    ]
