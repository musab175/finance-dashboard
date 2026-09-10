from datetime import timedelta

from odoo import api, fields, models


class BiztrasFinanceDashboard(models.AbstractModel):
    _name = "biztras.finance.dashboard"
    _description = "Biztras Finance Dashboard Data"

    @api.model
    def get_dashboard_data(self, report_date=None, period="month"):
        company = self.env.company
        today = (
            fields.Date.to_date(report_date)
            if report_date
            else fields.Date.context_today(self)
        )
        period = period if period in ("month", "quarter", "year") else "month"

        def get_period_start(date, period_name):
            if period_name == "year":
                return date.replace(month=1, day=1)
            if period_name == "quarter":
                quarter_month = ((date.month - 1) // 3) * 3 + 1
                return date.replace(month=quarter_month, day=1)
            return date.replace(day=1)

        month_start = get_period_start(today, period)
        ninety_days_ago = today - timedelta(days=90)
        previous_month_end = month_start - timedelta(days=1)
        previous_month_start = get_period_start(previous_month_end, period)
        elapsed_days = (today - month_start).days
        previous_period_end = min(
            previous_month_start + timedelta(days=elapsed_days),
            previous_month_end,
        )
        period_labels = {
            "month": ("This Month", "Last Month"),
            "quarter": ("This Quarter", "Previous Quarter"),
            "year": ("This Year", "Previous Year"),
        }
        previous_90_cutoff = previous_month_end - timedelta(days=90)

        # One round trip for every balance-sheet/P&L scalar this method needs,
        # current and previous period alike. Each is a small aggregate the
        # database computes in-place; the slow part on this connection is
        # round-trip latency itself, not per-row work, so the win comes from
        # collapsing many separate queries into one, not from lighter queries.
        self.env.cr.execute(
            """
            SELECT
                SUM(CASE WHEN l.date <= %(today)s
                    AND a.account_type = 'asset_cash'
                    THEN l.balance ELSE 0 END) AS cash_balance,
                SUM(CASE WHEN l.date <= %(today)s
                    AND a.account_type IN ('asset_current', 'asset_cash', 'asset_receivable')
                    THEN l.balance ELSE 0 END) AS current_assets,
                SUM(CASE WHEN l.date <= %(today)s
                    AND a.account_type IN ('liability_current', 'liability_payable')
                    THEN l.balance ELSE 0 END) AS current_liabilities,
                SUM(CASE WHEN l.date BETWEEN %(month_start)s AND %(today)s
                    AND a.account_type = 'expense_direct_cost'
                    THEN l.balance ELSE 0 END) AS direct_cost,
                SUM(CASE WHEN l.date BETWEEN %(month_start)s AND %(today)s
                    AND a.account_type IN ('expense', 'expense_depreciation', 'expense_direct_cost')
                    THEN l.balance ELSE 0 END) AS expenses,
                SUM(CASE WHEN l.date BETWEEN %(month_start)s AND %(today)s
                    AND a.account_type IN ('income', 'income_other')
                    THEN l.balance ELSE 0 END) AS income_raw,
                SUM(CASE WHEN l.date BETWEEN %(month_start)s AND %(today)s
                    AND a.account_type = 'income_other'
                    THEN l.balance ELSE 0 END) AS other_income_raw,
                SUM(CASE WHEN l.date <= %(previous_month_end)s
                    AND a.account_type = 'asset_cash'
                    THEN l.balance ELSE 0 END) AS previous_cash,
                SUM(CASE WHEN l.date <= %(previous_month_end)s
                    AND a.account_type = 'asset_receivable'
                    THEN l.balance ELSE 0 END) AS previous_receivables,
                SUM(CASE WHEN l.date <= %(previous_month_end)s
                    AND a.account_type = 'liability_payable'
                    THEN l.balance ELSE 0 END) AS previous_payables_raw,
                SUM(CASE WHEN l.date <= %(previous_month_end)s
                    AND a.account_type IN ('asset_current', 'asset_cash', 'asset_receivable')
                    THEN l.balance ELSE 0 END) AS previous_current_assets,
                SUM(CASE WHEN l.date <= %(previous_month_end)s
                    AND a.account_type IN ('liability_current', 'liability_payable')
                    THEN l.balance ELSE 0 END) AS previous_current_liabilities,
                SUM(CASE WHEN l.date BETWEEN %(previous_month_start)s AND %(previous_period_end)s
                    AND a.account_type IN ('expense', 'expense_depreciation', 'expense_direct_cost')
                    THEN l.balance ELSE 0 END) AS previous_expenses,
                SUM(CASE WHEN l.date BETWEEN %(previous_month_start)s AND %(previous_period_end)s
                    AND a.account_type = 'expense_direct_cost'
                    THEN l.balance ELSE 0 END) AS previous_direct_cost,
                SUM(CASE WHEN l.date BETWEEN %(previous_month_start)s AND %(previous_period_end)s
                    AND a.account_type IN ('income', 'income_other')
                    THEN l.balance ELSE 0 END) AS previous_income_raw,
                SUM(CASE WHEN l.date BETWEEN %(previous_month_start)s AND %(previous_period_end)s
                    AND a.account_type = 'income_other'
                    THEN l.balance ELSE 0 END) AS previous_other_income_raw,
                SUM(CASE WHEN l.date <= %(previous_month_end)s
                    AND a.account_type = 'asset_receivable'
                    AND l.date_maturity IS NOT NULL
                    AND l.date_maturity <= %(previous_90_cutoff)s
                    THEN l.balance ELSE 0 END) AS previous_overdue_90
            FROM account_move_line l
            JOIN account_account a ON a.id = l.account_id
            WHERE l.company_id = %(company_id)s
              AND l.parent_state = 'posted'
              AND l.date <= %(today)s
            """,
            {
                "company_id": company.id,
                "today": today,
                "month_start": month_start,
                "previous_month_end": previous_month_end,
                "previous_month_start": previous_month_start,
                "previous_period_end": previous_period_end,
                "previous_90_cutoff": previous_90_cutoff,
            },
        )
        totals = {
            key: (value or 0.0)
            for key, value in (self.env.cr.dictfetchone() or {}).items()
        }

        cash_balance = totals["cash_balance"]
        current_assets = totals["current_assets"]
        current_liabilities = -totals["current_liabilities"]
        direct_cost = totals["direct_cost"]
        expenses = totals["expenses"]
        income = -totals["income_raw"]
        other_income = -totals["other_income_raw"]
        operating_expenses = expenses - direct_cost

        # Sales, current and previous period, in one query: grouped by day
        # in SQL rather than fetched one row per invoice and summed in
        # Python. On a busy period (especially period="year", which can
        # span up to ~2 years of invoices) this cuts the transfer from
        # "one row per invoice" down to "one row per day that had sales".
        self.env.cr.execute(
            """
            SELECT invoice_date, SUM(amount_total_signed) AS daily_total
            FROM account_move
            WHERE company_id = %(company_id)s
              AND state = 'posted'
              AND move_type IN ('out_invoice', 'out_refund')
              AND invoice_date BETWEEN %(previous_month_start)s AND %(today)s
            GROUP BY invoice_date
            """,
            {
                "company_id": company.id,
                "today": today,
                "previous_month_start": previous_month_start,
            },
        )
        current_daily_sales = {}
        previous_daily_sales = {}
        for row in self.env.cr.dictfetchall():
            invoice_date = row["invoice_date"]
            amount = row["daily_total"] or 0.0
            if month_start <= invoice_date <= today:
                current_daily_sales[invoice_date] = amount
            elif previous_month_start <= invoice_date <= previous_period_end:
                previous_daily_sales[invoice_date] = amount

        mtd_sales = sum(current_daily_sales.values())
        today_sales = current_daily_sales.get(today, 0.0)
        previous_mtd_sales = sum(previous_daily_sales.values())
        previous_day_sales = previous_daily_sales.get(previous_period_end, 0.0)
        gross_profit = mtd_sales - direct_cost

        def cumulative_daily_sales(daily_totals, start_date, day_count):
            running_total = 0.0
            values = []
            for offset in range(day_count):
                date = start_date + timedelta(days=offset)
                running_total += daily_totals.get(date, 0.0)
                values.append(running_total)
            return values

        chart_day_count = elapsed_days + 1
        current_sales_chart = cumulative_daily_sales(
            current_daily_sales, month_start, chart_day_count
        )
        previous_sales_chart = cumulative_daily_sales(
            previous_daily_sales, previous_month_start, chart_day_count
        )

        # Sales by product category, current period, grouped in SQL instead
        # of fetched line-by-line and chased through product -> category and
        # move -> move_type in Python (each of those was its own round trip
        # per distinct value).
        self.env.cr.execute(
            """
            SELECT
                cat.id AS category_id,
                cat.complete_name AS category_name,
                SUM(l.price_subtotal * CASE WHEN m.move_type = 'out_refund' THEN -1 ELSE 1 END)
                    AS category_total
            FROM account_move_line l
            JOIN account_move m ON m.id = l.move_id
            JOIN product_product pp ON pp.id = l.product_id
            JOIN product_template pt ON pt.id = pp.product_tmpl_id
            JOIN product_category cat ON cat.id = pt.categ_id
            WHERE m.company_id = %(company_id)s
              AND m.state = 'posted'
              AND m.move_type IN ('out_invoice', 'out_refund')
              AND m.invoice_date BETWEEN %(month_start)s AND %(today)s
              AND l.display_type = 'product'
              AND l.product_id IS NOT NULL
            GROUP BY cat.id, cat.complete_name
            """,
            {
                "company_id": company.id,
                "today": today,
                "month_start": month_start,
            },
        )
        category_totals = {
            row["category_name"]: row["category_total"] or 0.0
            for row in self.env.cr.dictfetchall()
        }
        category_items = sorted(
            (
                {"name": name, "value": value}
                for name, value in category_totals.items()
                if value > 0
            ),
            key=lambda item: item["value"],
            reverse=True,
        )
        if len(category_items) > 4:
            other_value = sum(item["value"] for item in category_items[3:])
            category_items = category_items[:3] + [
                {"name": "Other", "value": other_value}
            ]
        category_total = sum(item["value"] for item in category_items)
        for item in category_items:
            item["percentage"] = (
                item["value"] / category_total * 100 if category_total else 0.0
            )

        def percentage_change(current, previous):
            if not previous:
                return None
            return (current - previous) / abs(previous) * 100

        previous_cash = totals["previous_cash"]
        previous_receivables = totals["previous_receivables"]
        previous_payables = abs(totals["previous_payables_raw"])
        previous_expenses = totals["previous_expenses"]
        previous_direct_cost = totals["previous_direct_cost"]
        previous_income = -totals["previous_income_raw"]
        previous_other_income = -totals["previous_other_income_raw"]
        previous_operating_expenses = previous_expenses - previous_direct_cost
        previous_gross_profit = previous_mtd_sales - previous_direct_cost
        previous_gross_profit_percent = (
            previous_gross_profit / previous_mtd_sales * 100
            if previous_mtd_sales else 0.0
        )
        previous_net_profit = previous_income - previous_expenses
        previous_current_assets = totals["previous_current_assets"]
        previous_current_liabilities = -totals["previous_current_liabilities"]
        previous_working_capital = (
            previous_current_assets - previous_current_liabilities
        )

        # Open AR/AP lines, current period, in one query. This feeds total
        # receivables/payables, the 90+ overdue figure, the aging buckets and
        # the top-5 overdue tables - previously four separate concerns each
        # re-walking a freshly re.search()'d recordset.
        self.env.cr.execute(
            """
            SELECT l.partner_id, l.amount_residual, l.date_maturity, a.account_type
            FROM account_move_line l
            JOIN account_account a ON a.id = l.account_id
            WHERE l.company_id = %(company_id)s
              AND l.parent_state = 'posted'
              AND l.reconciled = false
              AND l.date <= %(today)s
              AND a.account_type IN ('asset_receivable', 'liability_payable')
            """,
            {
                "company_id": company.id,
                "today": today,
            },
        )
        ar_ap_rows = self.env.cr.dictfetchall()
        receivable_rows = [
            row for row in ar_ap_rows if row["account_type"] == "asset_receivable"
        ]
        payable_rows = [
            row for row in ar_ap_rows if row["account_type"] == "liability_payable"
        ]

        total_receivables = sum(
            row["amount_residual"] or 0.0 for row in receivable_rows
        )
        overdue_90 = sum(
            row["amount_residual"] or 0.0
            for row in receivable_rows
            if row["date_maturity"] and row["date_maturity"] <= ninety_days_ago
        )
        previous_overdue_90 = totals["previous_overdue_90"]
        total_payables = abs(
            sum(row["amount_residual"] or 0.0 for row in payable_rows)
        )
        net_profit = income - expenses
        working_capital = current_assets - current_liabilities

        def overdue_by_partner(rows, payable=False):
            partners = {}
            for row in rows:
                date_maturity = row["date_maturity"]
                amount_residual = row["amount_residual"]
                if not date_maturity or date_maturity >= today or not amount_residual:
                    continue
                entry = partners.setdefault(row["partner_id"], {
                    "amount": 0.0,
                    "days": 0,
                })
                entry["amount"] += -amount_residual if payable else amount_residual
                entry["days"] = max(entry["days"], (today - date_maturity).days)
            return partners

        receivable_overdue = overdue_by_partner(receivable_rows)
        payable_overdue = overdue_by_partner(payable_rows, payable=True)
        partner_ids = {
            partner_id
            for partner_id in set(receivable_overdue) | set(payable_overdue)
            if partner_id
        }
        partner_names = {
            partner.id: partner.display_name
            for partner in self.env["res.partner"].browse(partner_ids)
        }

        def top_overdue_partners(overdue_by_id):
            rows = [
                {
                    "name": partner_names.get(partner_id, "Unassigned"),
                    "amount": data["amount"],
                    "days": data["days"],
                }
                for partner_id, data in overdue_by_id.items()
            ]
            return sorted(
                (row for row in rows if row["amount"] > 0),
                key=lambda row: row["amount"],
                reverse=True,
            )[:5]

        top_overdue_customers = top_overdue_partners(receivable_overdue)
        top_overdue_suppliers = top_overdue_partners(payable_overdue)

        aging = {
            "0 - 30 Days": 0.0,
            "31 - 60 Days": 0.0,
            "61 - 90 Days": 0.0,
            "90+ Days": 0.0,
        }
        for row in receivable_rows:
            days = max(0, (today - (row["date_maturity"] or today)).days)
            if days <= 30:
                bucket = "0 - 30 Days"
            elif days <= 60:
                bucket = "31 - 60 Days"
            elif days <= 90:
                bucket = "61 - 90 Days"
            else:
                bucket = "90+ Days"
            aging[bucket] += row["amount_residual"] or 0.0
        aging_total = sum(aging.values())
        aging_rows = [
            {
                "label": label,
                "amount": amount,
                "percentage": amount / aging_total * 100 if aging_total else 0.0,
            }
            for label, amount in aging.items()
        ]

        self.env.cr.execute(
            """
            SELECT
                l.account_id AS account_id,
                SUM(CASE WHEN l.date BETWEEN %(month_start)s AND %(today)s
                    THEN l.balance ELSE 0 END) AS current_total,
                SUM(CASE WHEN l.date BETWEEN %(previous_month_start)s AND %(previous_period_end)s
                    THEN l.balance ELSE 0 END) AS previous_total
            FROM account_move_line l
            JOIN account_account a ON a.id = l.account_id
            WHERE l.company_id = %(company_id)s
              AND l.parent_state = 'posted'
              AND a.account_type IN ('expense', 'expense_depreciation', 'expense_direct_cost')
              AND l.date BETWEEN %(previous_month_start)s AND %(today)s
            GROUP BY l.account_id
            """,
            {
                "company_id": company.id,
                "today": today,
                "month_start": month_start,
                "previous_month_start": previous_month_start,
                "previous_period_end": previous_period_end,
            },
        )
        expense_group_rows = self.env.cr.dictfetchall()
        account_names = {
            account.id: account.display_name
            for account in self.env["account.account"].browse(
                [row["account_id"] for row in expense_group_rows]
            )
        }
        current_expense_accounts = {
            account_names[row["account_id"]]: row["current_total"] or 0.0
            for row in expense_group_rows
        }
        previous_expense_accounts = {
            account_names[row["account_id"]]: row["previous_total"] or 0.0
            for row in expense_group_rows
        }
        expense_account_names = set(current_expense_accounts) | set(
            previous_expense_accounts
        )
        expense_rows = [
            {
                "name": name,
                "current": current_expense_accounts.get(name, 0.0),
                "previous": previous_expense_accounts.get(name, 0.0),
                "variance": (
                    current_expense_accounts.get(name, 0.0)
                    - previous_expense_accounts.get(name, 0.0)
                ),
            }
            for name in expense_account_names
        ]
        expense_rows.sort(
            key=lambda row: abs(row["current"]), reverse=True
        )
        expense_rows = expense_rows[:5]
        updated_at = fields.Datetime.context_timestamp(self, fields.Datetime.now())

        return {
            "currency": company.currency_id.symbol or company.currency_id.name,
            "report_date": today.strftime("%d %b %Y"),
            "report_date_iso": fields.Date.to_string(today),
            "period": period,
            "period_label": period_labels[period][0],
            "comparison_label": period_labels[period][1],
            "updated_at": updated_at.strftime("%d %b %Y %I:%M %p"),
            "cash_balance": cash_balance,
            "cash_balance_change": percentage_change(cash_balance, previous_cash),
            "today_sales": today_sales,
            "today_sales_change": percentage_change(today_sales, previous_day_sales),
            "mtd_sales": mtd_sales,
            "mtd_sales_change": percentage_change(mtd_sales, previous_mtd_sales),
            "sales_chart": {
                "labels": [
                    (month_start + timedelta(days=offset)).strftime("%d %b")
                    for offset in range(chart_day_count)
                ],
                "current": current_sales_chart,
                "previous": previous_sales_chart,
            },
            "sales_by_category": category_items,
            "gross_profit_percent": gross_profit / mtd_sales * 100 if mtd_sales else 0.0,
            "gross_profit_percent_change": (
                gross_profit / mtd_sales * 100 if mtd_sales else 0.0
            ) - previous_gross_profit_percent,
            "net_profit": net_profit,
            "net_profit_change": percentage_change(net_profit, previous_net_profit),
            "total_receivables": total_receivables,
            "total_receivables_change": percentage_change(
                total_receivables, previous_receivables
            ),
            "overdue_90": overdue_90,
            "overdue_90_change": percentage_change(
                overdue_90, previous_overdue_90
            ),
            "total_payables": total_payables,
            "total_payables_change": percentage_change(
                total_payables, previous_payables
            ),
            "expenses": expenses,
            "expenses_change": percentage_change(expenses, previous_expenses),
            "working_capital": working_capital,
            "working_capital_change": percentage_change(
                working_capital, previous_working_capital
            ),
            "pnl": {
                "sales": mtd_sales,
                "sales_change": percentage_change(
                    mtd_sales, previous_mtd_sales
                ),
                "cogs": direct_cost,
                "cogs_change": percentage_change(
                    direct_cost, previous_direct_cost
                ),
                "gross_profit": gross_profit,
                "gross_profit_change": percentage_change(
                    gross_profit, previous_gross_profit
                ),
                "gross_profit_percent": (
                    gross_profit / mtd_sales * 100 if mtd_sales else 0.0
                ),
                "gross_profit_percent_change": (
                    gross_profit / mtd_sales * 100 if mtd_sales else 0.0
                ) - previous_gross_profit_percent,
                "operating_expenses": operating_expenses,
                "operating_expenses_change": percentage_change(
                    operating_expenses, previous_operating_expenses
                ),
                "other_income": other_income,
                "other_income_change": percentage_change(
                    other_income, previous_other_income
                ),
                "net_profit": net_profit,
                "net_profit_change": percentage_change(
                    net_profit, previous_net_profit
                ),
            },
            "top_overdue_customers": top_overdue_customers,
            "receivable_aging": {
                "rows": aging_rows,
                "total": aging_total,
            },
            "top_overdue_suppliers": top_overdue_suppliers,
            "expenses_by_account": {
                "rows": expense_rows,
                "current_total": expenses,
                "previous_total": previous_expenses,
                "variance_total": expenses - previous_expenses,
            },
        }
