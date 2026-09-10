{
    "name": "Biztras Finance Dashboard",
    "version": "17.0.1.0.0",
    "category": "Accounting",
    "summary": "Custom finance dashboard",
    "author": "Biztras",
    "license": "LGPL-3",
    "depends": [
        "web",
        "account",
        "sale_management",
        "purchase",
    ],
    "data": [
        "views/dashboard_views.xml",
    ],
    "assets": {
        "web.assets_backend": [
            "biztras_finance_dashboard/static/src/js/finance_dashboard.js",
            "biztras_finance_dashboard/static/src/xml/finance_dashboard.xml",
            "biztras_finance_dashboard/static/src/scss/finance_dashboard.scss",
        ],
    },
    "application": True,
    "installable": True,
}