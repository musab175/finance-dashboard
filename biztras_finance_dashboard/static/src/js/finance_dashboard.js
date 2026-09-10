/** @odoo-module **/

import { Component, onWillStart, useState } from "@odoo/owl";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";

export class FinanceDashboard extends Component {
    static template = "biztras_finance_dashboard.FinanceDashboard";

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.state = useState({
            loading: true,
            error: null,
            data: {},
            reportDate: null,
            period: "month",
            showFilters: false,
        });
        onWillStart(() => this.loadData());
    }

    async loadData() {
        this.state.loading = true;
        this.state.error = null;
        try {
            const data = await this.orm.call(
                "biztras.finance.dashboard",
                "get_dashboard_data",
                [this.state.reportDate || false, this.state.period]
            );
            this.state.data = data;
            this.state.reportDate = data.report_date_iso;
            this.state.period = data.period;
        } catch (error) {
            console.error("Could not load Biztras dashboard data", error);
            this.state.error = "Live finance data could not be loaded.";
        } finally {
            this.state.loading = false;
        }
    }

    async onDateChange(event) {
        this.state.reportDate = event.target.value;
        await this.loadData();
    }

    async onPeriodChange(event) {
        this.state.period = event.target.value;
        await this.loadData();
    }

    toggleFilters() {
        this.state.showFilters = !this.state.showFilters;
    }

    async resetFilters() {
        this.state.reportDate = null;
        this.state.period = "month";
        this.state.showFilters = false;
        await this.loadData();
    }

    openOverdueCustomers() {
        return this.openOverdueLines("asset_receivable", "Overdue Customers");
    }

    openOverdueSuppliers() {
        return this.openOverdueLines("liability_payable", "Overdue Suppliers");
    }

    openOverdueLines(accountType, name) {
        return this.action.doAction({
            type: "ir.actions.act_window",
            name,
            res_model: "account.move.line",
            views: [[false, "list"], [false, "form"]],
            target: "current",
            domain: [
                ["account_id.account_type", "=", accountType],
                ["parent_state", "=", "posted"],
                ["reconciled", "=", false],
                ["date_maturity", "<", this.state.reportDate],
            ],
        });
    }

    formatMoney(value) {
        const amount = Number(value || 0);
        const formatted = new Intl.NumberFormat("en-US", {
            maximumFractionDigits: 0,
        }).format(Math.abs(amount));
        const currency = this.state.data.currency || "AED";
        return amount < 0
            ? `${currency} (${formatted})`
            : `${currency} ${formatted}`;
    }

    formatPercent(value) {
        return `${Number(value || 0).toFixed(1)}%`;
    }

    formatNumber(value) {
        return new Intl.NumberFormat("en-US", {
            maximumFractionDigits: 0,
        }).format(Number(value || 0));
    }

    formatVariance(value) {
        const number = Number(value || 0);
        const sign = number > 0 ? "+" : "";
        const arrow = number > 0 ? "↗" : number < 0 ? "↘" : "→";
        return `${sign}${this.formatNumber(number)} ${arrow}`;
    }

    formatChange(value, unit = "%") {
        if (value === null || value === undefined) {
            return "N/A";
        }
        const number = Number(value);
        const sign = number > 0 ? "+" : "";
        const arrow = number > 0 ? "↗" : number < 0 ? "↘" : "→";
        return `${sign}${number.toFixed(1)}${unit} ${arrow}`;
    }

    changeClass(value, inverse = false) {
        if (value === null || value === undefined) {
            return "";
        }
        const favorable = inverse ? Number(value) <= 0 : Number(value) >= 0;
        return favorable ? "md-positive" : "md-negative";
    }

    chartPoints(values = []) {
        if (!values.length) {
            return "";
        }
        const chart = this.state.data.sales_chart || {};
        const allValues = [
            ...(chart.current || []),
            ...(chart.previous || []),
            0,
        ].map(Number);
        const minimum = Math.min(...allValues);
        const maximum = Math.max(...allValues);
        const range = maximum - minimum || 1;
        const width = 495;
        return values.map((value, index) => {
            const x = 45 + (values.length === 1
                ? 0
                : (index / (values.length - 1)) * width);
            const y = 195 - ((Number(value) - minimum) / range) * 170;
            return `${x.toFixed(1)},${y.toFixed(1)}`;
        }).join(" ");
    }

    chartAxisLabels() {
        const labels = this.state.data.sales_chart?.labels || [];
        if (!labels.length) {
            return [];
        }
        const indexes = new Set();
        for (let step = 0; step < 6; step++) {
            indexes.add(Math.round((labels.length - 1) * step / 5));
        }
        return [...indexes].map((index) => ({
            x: 45 + (labels.length === 1
                ? 0
                : (index / (labels.length - 1)) * 495),
            label: labels[index],
        }));
    }

    chartYLabels() {
        const chart = this.state.data.sales_chart || {};
        const values = [
            ...(chart.current || []),
            ...(chart.previous || []),
            0,
        ].map(Number);
        if (!values.length) {
            return [];
        }
        const minimum = Math.min(...values);
        const maximum = Math.max(...values);
        return [
            { value: maximum, y: 28 },
            { value: (maximum + minimum) / 2, y: 113 },
            { value: minimum, y: 198 },
        ];
    }

    formatCompact(value) {
        return new Intl.NumberFormat("en-US", {
            notation: "compact",
            maximumFractionDigits: 1,
        }).format(Number(value || 0));
    }

    categoryColors() {
        return ["#6543b5", "#14998f", "#ed8736", "#3467ae"];
    }

    categoryColor(index) {
        return this.categoryColors()[index % this.categoryColors().length];
    }

    categoryGradient() {
        const categories = this.state.data.sales_by_category || [];
        if (!categories.length) {
            return "background: #e4e1e6;";
        }
        let start = 0;
        const segments = categories.map((category, index) => {
            const end = start + Number(category.percentage || 0);
            const segment = `${this.categoryColor(index)} ${start}% ${end}%`;
            start = end;
            return segment;
        });
        return `background: conic-gradient(${segments.join(", ")});`;
    }
}

registry.category("actions").add(
    "biztras_finance_dashboard.dashboard",
    FinanceDashboard
);
