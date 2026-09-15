# -*- coding: utf-8 -*-
{
    'name': 'Finance Dashboard',
    'version': '17.0.1.0.0',
    'category': 'Accounting/Accounting',
    'summary': 'Custom KPI finance dashboard (Cash & Bank, Sales, AR/AP, P&L, Aging)',
    'author': 'Your Company',
    'license': 'LGPL-3',
    'depends': ['base', 'web', 'account', 'sale'],
    'data': [
        'views/finance_dashboard_views.xml',
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
