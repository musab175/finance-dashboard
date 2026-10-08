# -*- coding: utf-8 -*-
"""ORM-managed schema for the five reporting tables (hybrid model).

WHAT THIS CHANGES AND WHAT IT DOES NOT
    Odoo now OWNS the DDL: installing the module creates the five tables, so a
    fresh deployment needs one command instead of two. The tables are still
    POPULATED by the validated SQL (02/03/04 via 05_refresh_all.sql), which is
    untouched. The aggregation logic that reconciles 85/85 against Odoo's report
    engine is not reimplemented here.

    01_create_summary.sql is DELIBERATELY RETAINED. It remains the only way to
    rebuild the layer without a working Odoo registry - the property that let
    psql alone recover the layer in 202 seconds on 1 and 4 October while the
    module was absent. Both paths must produce an identical schema; the
    reconciliation test in 09 - Testing exists to prove that.

FOUR THINGS THE ORM CANNOT EXPRESS, AND HOW EACH IS HANDLED
    1. COMPOSITE PRIMARY KEYS. Every Odoo model is forced to have an `id`
       serial primary key, so (company_id, date) cannot be the PK. Replaced with
       a UNIQUE constraint on the same columns. This is sufficient: ON CONFLICT
       needs a unique INDEX, which a UNIQUE constraint provides, so
       02_backfill_daily.sql's upsert continues to work unchanged.
    2. NUMERIC PRECISION. fields.Float(digits=...) produces an unconstrained
       `numeric` column, not numeric(18,2). Unconstrained numeric would NOT round
       on insert, so 02's bare SUM() could store more than two decimals where the
       SQL path rounds. init() therefore ALTERs the columns to numeric(18,2) to
       keep the two paths byte-identical.
    3. EXPRESSION AND COVERING INDEXES. The COALESCE-normalised unique index and
       the INCLUDE covering index cannot be declared on a field. Created in
       init() with the same DDL 01_create_summary.sql uses.
    4. FOREIGN KEYS. company_id / partner_id / account_id are plain Integer, NOT
       Many2one, deliberately. Many2one would add FK constraints the SQL path
       does not have, and a deleted partner would then break the refresh.

_log_access = False throughout: create_uid/create_date/write_uid/write_date on
500k rows is pure overhead for tables nothing writes through the ORM.
"""
from odoo import fields, models

AMT = dict(digits=(18, 2), required=True, default=0.0)


class FinanceDashboardDaily(models.Model):
    _name = 'finance.dashboard.daily'
    _description = 'Finance Dashboard - daily flows and snapshot deltas'
    _table = 'finance_dashboard_daily'
    _auto = True
    _log_access = False
    _order = 'company_id, date'

    company_id = fields.Integer(required=True, index=True)
    date = fields.Date(required=True, index=True)

    # FLOW - sum over a date range
    sales = fields.Float(**AMT)
    cogs = fields.Float(**AMT)
    opex = fields.Float(**AMT)
    other_income = fields.Float(**AMT)
    depreciation = fields.Float(**AMT)
    sales_ic = fields.Float(**AMT)
    cogs_ic = fields.Float(**AMT)

    # SNAPSHOT - cumulative-sum to a date, never summed as a range
    cash_bank_delta = fields.Float(**AMT)
    ar_delta = fields.Float(**AMT)
    ap_delta = fields.Float(**AMT)
    ar_ic_delta = fields.Float(**AMT)
    ap_ic_delta = fields.Float(**AMT)
    other_current_assets_delta = fields.Float(**AMT)
    other_current_liabilities_delta = fields.Float(**AMT)
    other_current_assets_ic_delta = fields.Float(**AMT)
    other_current_liabilities_ic_delta = fields.Float(**AMT)

    _sql_constraints = [(
        'finance_dashboard_daily_uk', 'UNIQUE (company_id, date)',
        'One row per company per accounting date.',
    )]

    def init(self):
        _force_numeric(self, [
            'sales', 'cogs', 'opex', 'other_income', 'depreciation',
            'sales_ic', 'cogs_ic',
            'cash_bank_delta', 'ar_delta', 'ap_delta', 'ar_ic_delta',
            'ap_ic_delta', 'other_current_assets_delta',
            'other_current_liabilities_delta', 'other_current_assets_ic_delta',
            'other_current_liabilities_ic_delta',
        ])


class FinanceDashboardArapDaily(models.Model):
    _name = 'finance.dashboard.arap.daily'
    _description = 'Finance Dashboard - AR/AP detail by maturity and partner'
    _table = 'finance_dashboard_arap_daily'
    _auto = True
    _log_access = False

    company_id = fields.Integer(required=True)
    date = fields.Date(required=True)
    date_maturity = fields.Date()
    partner_id = fields.Integer()
    is_intercompany = fields.Boolean(required=True, default=False)
    ar_amount = fields.Float(**AMT)
    ap_amount = fields.Float(**AMT)

    def init(self):
        _force_numeric(self, ['ar_amount', 'ap_amount'])
        # Deterministic grain key, required by the incremental merge in 03.
        # Two grain columns are nullable, so the index normalises them to
        # sentinels: plain equality on these expressions is indexable whereas
        # IS NOT DISTINCT FROM is not - that difference made the merge 43x
        # faster. Stored data is unchanged; NULLs stay NULL.
        self.env.cr.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS finance_dashboard_arap_uk
                ON finance_dashboard_arap_daily
                   (company_id, date,
                    COALESCE(date_maturity, DATE '9999-12-31'),
                    COALESCE(partner_id, -1),
                    is_intercompany);
            CREATE INDEX IF NOT EXISTS finance_dashboard_arap_daily_idx
                ON finance_dashboard_arap_daily (company_id, date);
        """)


class FinanceDashboardAgingDaily(models.Model):
    _name = 'finance.dashboard.aging.daily'
    _description = 'Finance Dashboard - aging, arap collapsed without partner'
    _table = 'finance_dashboard_aging_daily'
    _auto = True
    _log_access = False

    company_id = fields.Integer(required=True)
    date = fields.Date(required=True)
    date_maturity = fields.Date()
    # Deliberately UNCONSTRAINED numeric, matching 01_create_summary.sql:
    # SUM(numeric(18,2)) yields unconstrained numeric, and the original
    # CREATE TABLE AS produced that type. Kept so refreshed values stay
    # byte-identical to the pre-ORM implementation.
    ar_amount = fields.Float()
    ap_amount = fields.Float()

    def init(self):
        self.env.cr.execute("""
            CREATE INDEX IF NOT EXISTS finance_dashboard_aging_idx
                ON finance_dashboard_aging_daily (company_id, date)
                INCLUDE (date_maturity, ar_amount, ap_amount);
        """)


class FinanceDashboardExpenseDaily(models.Model):
    _name = 'finance.dashboard.expense.daily'
    _description = 'Finance Dashboard - expense detail by account'
    _table = 'finance_dashboard_expense_daily'
    _auto = True
    _log_access = False

    company_id = fields.Integer(required=True)
    date = fields.Date(required=True)
    account_id = fields.Integer(required=True)
    amount = fields.Float(**AMT)

    _sql_constraints = [(
        'finance_dashboard_expense_daily_uk',
        'UNIQUE (company_id, date, account_id)',
        'One row per company, date and account.',
    )]

    def init(self):
        _force_numeric(self, ['amount'])


class FinanceDashboardCoverage(models.Model):
    _name = 'finance.dashboard.coverage'
    _description = 'Finance Dashboard - refresh bookkeeping and data vintage'
    _table = 'finance_dashboard_coverage'
    _auto = True
    _log_access = False

    company_id = fields.Integer(required=True)
    covered_from = fields.Date()
    covered_to = fields.Date()
    dirty_from = fields.Date()
    last_refresh_at = fields.Datetime()
    last_refresh_ok = fields.Boolean()

    _sql_constraints = [(
        'finance_dashboard_coverage_uk', 'UNIQUE (company_id)',
        'One coverage row per company.',
    )]


def _force_numeric(model, columns):
    """Pin money columns to numeric(18,2).

    fields.Float(digits=...) yields an UNCONSTRAINED `numeric` column. That
    matters: 02_backfill_daily.sql inserts a bare SUM() and relies on the column
    type to round to two decimals. Without this, the ORM-created table would
    store more precision than the SQL-created one for the same input, and the
    two provisioning paths would diverge. Idempotent and cheap - PostgreSQL
    skips the rewrite when the type already matches.
    """
    for col in columns:
        model.env.cr.execute("""
            SELECT numeric_precision, numeric_scale
              FROM information_schema.columns
             WHERE table_name = %s AND column_name = %s
        """, (model._table, col))
        row = model.env.cr.fetchone()
        if row and (row[0], row[1]) != (18, 2):
            model.env.cr.execute(
                'ALTER TABLE "%s" ALTER COLUMN "%s" TYPE numeric(18,2)'
                % (model._table, col)
            )
