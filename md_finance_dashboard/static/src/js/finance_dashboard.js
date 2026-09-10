/** @odoo-module **/

import { Component } from "@odoo/owl";
import { registry } from "@web/core/registry";

export class FinanceDashboard extends Component {
    static template = "md_finance_dashboard.FinanceDashboard";
}

registry.category("actions").add(
    "md_finance_dashboard.dashboard",
    FinanceDashboard
);