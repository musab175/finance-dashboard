#!/usr/bin/env python3
"""
Container-local patch: excludes ir.ui.view and ir.asset records that belong
to modules whose code isn't present in this image (Enterprise + custom "bt_*"
modules), so view combination and asset-bundle building don't fail trying to
use leftover data from modules we can't load.

This never writes anything to the database - it only changes what this one
process reads in memory. Nothing here persists or affects any other client
connected to the same database.
"""
import odoo
from odoo.addons.base.models.ir_ui_view import View
from odoo.addons.base.models.ir_asset import IrAsset
from odoo.modules.module import get_manifest

_missing_cache = {}


def _get_missing_modules(cr):
    key = id(cr)
    if key not in _missing_cache:
        cr.execute("SELECT name FROM ir_module_module WHERE state IN ('installed', 'to upgrade')")
        installed = [r[0] for r in cr.fetchall()]
        _missing_cache[key] = frozenset(m for m in installed if not get_manifest(m))
    return _missing_cache[key]


def _excluded_ids(cr, model_name):
    missing = _get_missing_modules(cr)
    if not missing:
        return []
    cr.execute(
        "SELECT res_id FROM ir_model_data WHERE model = %s AND module IN %s",
        (model_name, tuple(missing)),
    )
    return [row[0] for row in cr.fetchall()]


_orig_view_domain = View._get_inheriting_views_domain


def _patched_view_domain(self):
    domain = _orig_view_domain(self)
    excluded = _excluded_ids(self.env.cr, "ir.ui.view")
    if excluded:
        domain = domain + [("id", "not in", tuple(excluded))]
    return domain


View._get_inheriting_views_domain = _patched_view_domain

_orig_related_assets = IrAsset._get_related_assets


def _patched_related_assets(self, domain):
    excluded = _excluded_ids(self.env.cr, "ir.asset")
    if excluded:
        domain = list(domain) + [("id", "not in", tuple(excluded))]
    return _orig_related_assets(self, domain)


IrAsset._get_related_assets = _patched_related_assets

if __name__ == "__main__":
    odoo.cli.main()
