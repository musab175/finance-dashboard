-- Migration: add the four IC-parity columns to an EXISTING reporting layer.
-- 2026-10-01.
--
-- WHY THIS FILE EXISTS SEPARATELY FROM 01:
--   01_create_summary.sql DROPs and recreates every table. On a deployment that
--   already holds a built reporting layer that would discard it and force a cold
--   rebuild (03 against an empty table exceeds 20 minutes). This migration adds
--   the same four columns in place instead.
--
-- SAFETY: ADD COLUMN ... DEFAULT 0 with a non-volatile default is a METADATA-ONLY
--   operation in PostgreSQL 11+. It does not rewrite the table and holds its
--   ACCESS EXCLUSIVE lock only for the catalogue update, so dashboard reads are
--   not blocked for any meaningful period.
--
-- IDEMPOTENT: IF NOT EXISTS on every statement. Safe to re-run.
--
-- AFTER RUNNING THIS, the new columns are all 0 until 02_backfill_daily.sql has
--   been re-run. A dashboard reading `base - ic` before that refresh gets the
--   UNFILTERED figure, which is exactly the pre-migration behaviour - it degrades
--   to the old result, it does not produce a wrong one.

ALTER TABLE finance_dashboard_daily
  ADD COLUMN IF NOT EXISTS sales_ic                           numeric(18,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cogs_ic                            numeric(18,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS other_current_assets_ic_delta      numeric(18,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS other_current_liabilities_ic_delta numeric(18,2) NOT NULL DEFAULT 0;

\echo '>>> IC parity columns present. Re-run 05_refresh_all.sql to populate them.'
