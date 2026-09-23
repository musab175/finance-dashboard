# -*- coding: utf-8 -*-
{
    'name': 'Finance Dashboard',
    'version': '17.0.4.0.0',
    'category': 'Accounting/Accounting',
    'summary': 'Custom KPI finance dashboard (Cash & Bank, Sales, AR/AP, P&L, Aging)',
    'author': 'Your Company',
    'license': 'LGPL-3',
    'depends': ['base', 'web', 'account', 'sale'],
    'data': [
        'security/ir.model.access.csv',
        'views/finance_dashboard_views.xml',
        # 'data/ir_cron_data.xml' is deliberately NOT loaded.
        #
        # It creates an ir.cron ("Finance Dashboard: Category Sales rollup
        # refresh") that is active by default and runs model._cron_refresh()
        # every 6 hours. Nothing reads what it produces: the Sales by Division
        # chart is served straight from finance_dashboard_daily (see the
        # comment above the division_totals query in controllers/main.py), and
        # this controller has zero references to the category-sales models or
        # their tables. Loading it on a server whose cron workers are enabled
        # would run a pointless 6-hourly job against the production ledger.
        #
        # The ORM models themselves are left in place: they are imported by
        # __init__.py and granted in security/ir.model.access.csv, so removing
        # them is a four-file change that would also orphan their two tables on
        # any database where the module is already installed. Inert without the
        # cron record, so they stay.
    ],
    'assets': {
        'web.assets_backend': [
            ('include', 'web.chartjs_lib'),
            'finance_dashboard/static/src/js/finance_dashboard.js',
            'finance_dashboard/static/src/xml/finance_dashboard.xml',
            'finance_dashboard/static/src/scss/finance_dashboard.scss',
        ],
    },
    'installable': True,
    'application': True,
}
