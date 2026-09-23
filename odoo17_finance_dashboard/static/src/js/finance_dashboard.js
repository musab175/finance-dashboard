/** @odoo-module **/

import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { Component, onWillStart, onMounted, onPatched, useRef, useState } from "@odoo/owl";

const CATEGORY_COLORS = ["#6C3F8F", "#9B6FC9", "#C7A8E8", "#E4D4F5", "#F1E9FA"];

export class FinanceDashboard extends Component {
    setup() {
        this.rpc = useService("rpc");
        this.action = useService("action");
        // Reuses the existing top-bar company switcher's state - not a
        // dashboard-specific filter. See _fetchData() below for how its
        // current selection is sent to the backend.
        this.company = useService("company");
        this.salesChartRef = useRef("salesChart");
        this.categoryChartRef = useRef("categoryChart");
        this.charts = { sales: null, category: null };
        // Incrementing token so a slow, older request (e.g. for a
        // previously-selected date) can't overwrite a newer one's result
        // if it happens to resolve later - without this, changing the
        // date/period while a request is still in flight could silently
        // display stale, wrong-period data once the older response lands.
        this._fetchToken = 0;
        // Tracks which state.data object is currently drawn on the charts,
        // so onPatched (which fires on every DOM patch, not just data
        // changes - e.g. typing into a date field before the fetch
        // resolves) only redraws when the data actually changed.
        this._renderedData = null;

        this.state = useState({
            data: null,
            loading: true,
            error: null,
            asOf: new Date().toISOString().slice(0, 10),
            period: "month",
            compare: "previous_period",
        });

        onWillStart(() => this._fetchData());

        onMounted(() => {
            if (this.state.data) {
                this._renderCharts();
                this._renderedData = this.state.data;
            }
        });

        // Chart.js needs the canvas elements to exist in the DOM before it
        // can attach to them, and the canvases live inside the
        // state.loading-gated block that OWL tears down and rebuilds on
        // every fetch (not just the first). onPatched is OWL's own
        // guaranteed-after-DOM-update hook - fired synchronously by OWL's
        // scheduler right after it finishes patching, unlike a manually
        // scheduled requestAnimationFrame call, which races OWL's own
        // internal (also RAF-based) render flush with no ordering
        // guarantee between the two.
        onPatched(() => {
            if (!this.state.loading && this.state.data && this.state.data !== this._renderedData) {
                this._renderCharts();
                this._renderedData = this.state.data;
            }
        });
    }

    async _fetchData() {
        const token = ++this._fetchToken;
        this.state.loading = true;
        this.state.error = null;
        try {
            const data = await this.rpc("/finance_dashboard/data", {
                as_of: this.state.asOf,
                period: this.state.period,
                compare: this.state.compare,
                company_ids: this.company.activeCompanyIds,
            });
            // A newer request has started since this one was sent - its
            // result belongs to a filter selection that's no longer
            // current, so discard it rather than overwrite fresher data.
            if (token !== this._fetchToken) {
                return;
            }
            this.state.data = data;
        } catch (e) {
            if (token !== this._fetchToken) {
                return;
            }
            this.state.error = "Could not load dashboard data.";
            console.error(e);
        } finally {
            if (token === this._fetchToken) {
                this.state.loading = false;
            }
        }
    }

    async onRefresh() {
        await this._fetchData();
    }

    async onFilterChange(ev) {
        const { name, value } = ev.target;
        this.state[name] = value;
        await this._fetchData();
    }

openOverdueCustomers() {
        this.action.doAction({
            type: "ir.actions.act_window",
            name: "Overdue Customer Invoices",
            res_model: "account.move",
            views: [[false, "list"], [false, "form"]],
            domain: [
                ["move_type", "in", ["out_invoice", "out_refund"]],
                ["state", "=", "posted"],
                ["payment_state", "in", ["not_paid", "partial"]],
            ],
            target: "current",
        });
    }

    openOverdueSuppliers() {
        this.action.doAction({
            type: "ir.actions.act_window",
            name: "Overdue Vendor Bills",
            res_model: "account.move",
            views: [[false, "list"], [false, "form"]],
            domain: [
                ["move_type", "in", ["in_invoice", "in_refund"]],
                ["state", "=", "posted"],
                ["payment_state", "in", ["not_paid", "partial"]],
            ],
            target: "current",
        });
    }

    fmt(value) {
        if (value === null || value === undefined) return "N/A";
        return "AED " + Number(value).toLocaleString(undefined, { maximumFractionDigits: 0 });
    }

    fmtDelta(value) {
        if (value === null || value === undefined) return "N/A";
        return (value > 0 ? "+" : "") + this.fmt(value);
    }

    pct(value) {
        if (value === null || value === undefined) return "N/A";
        return (value > 0 ? "+" : "") + value + "%";
    }

    pts(value) {
        if (value === null || value === undefined) return "N/A";
        return (value > 0 ? "+" : "") + value.toFixed(1) + " pts";
    }

    trend(value) {
        if (value === null || value === undefined) return "flat";
        return value > 0 ? "up" : value < 0 ? "down" : "flat";
    }

    // Whether the Sales Analysis chart has anything worth drawing.
    //
    // Unlike category_sales - which is sparse, so an empty period gives a
    // zero-length array a `.length` check can catch - sales_trend is always
    // dense: the backend returns one bucket per day in the period whether or
    // not anything was sold, so `labels.length` is never 0 and cannot detect
    // an empty period. A holding company like GFT Parent therefore produced a
    // flat line on a -1..1 axis, which reads as a broken chart rather than as
    // "no sales".
    //
    // Both series are checked: if this period is empty but the comparison
    // period is not, the chart still carries real information (the drop to
    // zero) and must be drawn.
    hasSalesTrend() {
        const t = this.state.data && this.state.data.sales_trend;
        if (!t) return false;
        return (t.actual || []).some((v) => v) || (t.last_month || []).some((v) => v);
    }

    // For metrics where a rise is unfavorable (payables, overdue receivables,
    // expenses, COGS): flip the color so "more" still reads as red.
    inverseTrend(value) {
        if (value === null || value === undefined) return "flat";
        return value > 0 ? "down" : value < 0 ? "up" : "flat";
    }

    categoryColor(index) {
        return CATEGORY_COLORS[index % CATEGORY_COLORS.length];
    }

    categoryPct(amount) {
        const total = this.state.data.category_sales_total;
        if (!total) return "0.0";
        return ((amount / total) * 100).toFixed(1);
    }

    _destroyCharts() {
        if (this.charts.sales) {
            this.charts.sales.destroy();
            this.charts.sales = null;
        }
        if (this.charts.category) {
            this.charts.category.destroy();
            this.charts.category = null;
        }
    }

    _renderCharts() {
        // Called only from onMounted/onPatched, both of which OWL guarantees
        // run after the DOM (including the canvas elements) has already
        // been committed - no requestAnimationFrame guesswork needed here.
        const data = this.state.data;
        if (!data) return;
        this._destroyCharts();

        if (this.salesChartRef.el) {
            this.charts.sales = new Chart(this.salesChartRef.el.getContext("2d"), {
                type: "line",
                data: {
                    labels: data.sales_trend.labels,
                    datasets: [
                        {
                            label: "Actual Sales",
                            data: data.sales_trend.actual,
                            borderColor: "#6C3F8F",
                            backgroundColor: "rgba(108,63,143,0.08)",
                            tension: 0.35,
                            fill: true,
                            pointRadius: 0,
                            borderWidth: 2,
                        },
                        {
                            label: data.compare_label,
                            data: data.sales_trend.last_month,
                            borderColor: "#B0AAB8",
                            borderDash: [5, 5],
                            fill: false,
                            pointRadius: 0,
                            borderWidth: 2,
                        },
                    ],
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: { legend: { display: true, position: "top", align: "start" } },
                    scales: { y: { beginAtZero: false } },
                },
            });
        }

        if (this.categoryChartRef.el && data.category_sales.length) {
            this.charts.category = new Chart(this.categoryChartRef.el.getContext("2d"), {
                type: "doughnut",
                data: {
                    labels: data.category_sales.map((c) => c.name),
                    datasets: [
                        {
                            data: data.category_sales.map((c) => c.amount),
                            backgroundColor: data.category_sales.map((c, i) => this.categoryColor(i)),
                            borderWidth: 0,
                        },
                    ],
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    cutout: "70%",
                    plugins: { legend: { display: false } },
                },
            });
        }
    }
}

FinanceDashboard.template = "finance_dashboard.Dashboard";

registry.category("actions").add("finance_dashboard.dashboard", FinanceDashboard);
