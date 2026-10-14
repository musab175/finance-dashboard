# -*- coding: utf-8 -*-
# =============================================================================
# 12a_refresh_transaction.py - Finance Dashboard bootstrap, SECTION 4: the
# refresh transaction. 2026-10-13.
#
# RUN ONLY BY 12_refresh.sh. It feeds this file to `odoo shell` on stdin and
# passes every instruction in FD4_* environment variables. Run any other way,
# this file refuses before it touches anything.
#
# ONE TRANSACTION on Odoo's cursor, which is REPEATABLE READ: the build and all
# 23 checks read one snapshot of the ledger.
#   0. rollback      end odoo shell's start-up transaction; ours begins at 1
#   1. identity      isolation must be REPEATABLE READ; the database, its uuid
#                    and the cluster start time must equal the pre-check's
#   2. files         every file this transaction runs is hashed against its
#                    pin: refresh_full()'s own file and 02/03/04 in the module
#                    copy Odoo actually loaded, and the guard, clear, 06b and
#                    06c in Section 4's folder. The SQL executed is the very
#                    bytes that were hashed.
#   3. lock_timeout  SET LOCAL, so a conflicting lock fails the run instead of
#                    waiting for ever
#   4. guard         00_guard_account_types.sql
#   5. clear         12b_clear_upsert_tables.sql (daily, expense_daily, coverage)
#   6. build         refresh_full(): 02 -> 03 -> 04, unchanged
#   7. gate          06b (16 checks) and 06c (7 checks): every row must PASS
#   8. commit        live mode only, and only after 1-7 passed. Otherwise ROLLBACK.
# Steps 0-4 write nothing. The first write is step 5 - or, in a test mode, the
# made-up rows injected just before it.
#
# TEST MODES NEVER COMMIT. commit_allowed is true only for FD4_MODE=live with
# FD4_INJECT=none. finish() is the only place that calls commit, and it checks
# commit_allowed first. A missing, empty or misspelt value is refused before the
# transaction starts.
#   FD4_MODE=rollback-only   steps 0-7, then always ROLLBACK
#   FD4_INJECT=before-build  (L-A) after the guard, one made-up row in each
#                            table the clear empties: daily and expense_daily
#                            dated 1900-01-01, coverage for company -1. The clear
#                            must remove all three, then every check must pass.
#   FD4_INJECT=after-build   (L-B) after refresh_full(), a daily row with sales
#                            1.00 and an expense row of 1.00, both dated
#                            1900-01-01. The gate must fail on exactly 06b sales
#                            +1.00 and 06c expense +1.00.
# Injected rows go only into reporting tables, never into the ledger, and only
# ever inside a transaction that is rolled back.
#
# OUTPUT: one line per fact, "FD4|<key>|<value>|...", flushed at once; values
# never contain "|". 12_refresh.sh decides the result from these lines, not
# from odoo's exit status. The last line is always the outcome:
#   FD4|outcome|COMMITTED              commit() returned: PostgreSQL confirmed it
#   FD4|outcome|UNKNOWN|<error>        commit() raised: the outcome must be
#                                      checked through a fresh connection
#   FD4|outcome|ROLLED_BACK|refused|.. a precondition failed; nothing written
#   FD4|outcome|ROLLED_BACK|gate|..    the guard or a check failed, or test rows
#                                      survived the clear
#   FD4|outcome|ROLLED_BACK|test|..    a test mode passed every check
#   FD4|outcome|ROLLED_BACK|error|..   an exception; the transaction is discarded
# This file never calls sys.exit, never writes a file and never runs VACUUM.
#
# Every statement goes to cr.execute() without parameters, and none contains a
# percent sign, so psycopg2 interpolates nothing.
# =============================================================================
import hashlib
import os
import re
import sys
import time
import traceback
from decimal import Decimal, InvalidOperation

MODES = ('live', 'rollback-only')
INJECTS = ('none', 'before-build', 'after-build')
REQUIRED = ('FD4_MODE', 'FD4_INJECT', 'FD4_DIR', 'FD4_MODULE_DIR',
            'FD4_EXPECTED_DB', 'FD4_EXPECTED_UUID', 'FD4_PRE_POSTMASTER_START',
            'FD4_LOCK_TIMEOUT', 'FD4_PINS')
STAGES = ('02_backfill_daily.sql', '03_backfill_arap.sql',
          '04_backfill_expense_and_derived.sql')
LAYER_FILE = 'models/finance_dashboard_layer.py'
GUARD = '00_guard_account_types.sql'
CLEAR = '12b_clear_upsert_tables.sql'
GATE = (('06b', '06b_validate_live_inline.sql', 16),
        ('06c', '06c_validate_cross_table.sql', 7))
# L-B: the only failures the two after-build rows can cause.
L_B_EXPECTED = {('06b', 'sales', '1.00'),
                ('06c', 'expense    = opex+cogs+dep', '1.00')}

IDENTITY_SQL = """/* fd4:identity */
SELECT current_setting('transaction_isolation'),
       current_database(),
       (SELECT value FROM ir_config_parameter WHERE key = 'database.uuid'),
       to_char(pg_postmaster_start_time() AT TIME ZONE 'UTC',
               'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
       current_setting('statement_timeout'),
       current_setting('idle_in_transaction_session_timeout'),
       current_setting('synchronous_commit')"""

ROWS_SQL = """/* fd4:rows */
SELECT (SELECT count(*) FROM finance_dashboard_daily),
       (SELECT count(*) FROM finance_dashboard_arap_daily),
       (SELECT count(*) FROM finance_dashboard_aging_daily),
       (SELECT count(*) FROM finance_dashboard_expense_daily),
       (SELECT count(*) FROM finance_dashboard_coverage)"""

# The SAME text 12_refresh.sh runs before and after the transaction.
STAMP_SQL = "SELECT COALESCE(to_char(max(last_refresh_at), 'YYYY-MM-DD HH24:MI:SS.US'), '') FROM finance_dashboard_coverage"

RESIDUE_SQL = """/* fd4:residue */
SELECT (SELECT count(*) FROM finance_dashboard_daily
         WHERE date = DATE '1900-01-01'),
       (SELECT count(*) FROM finance_dashboard_expense_daily
         WHERE date = DATE '1900-01-01'),
       (SELECT count(*) FROM finance_dashboard_coverage WHERE company_id = -1)"""

# TEST ONLY, reporting tables only. Every NOT NULL column is given a value: the
# ORM creates these columns without database defaults (Step 0(b), 2026-10-13).
INJECT_DAILY = """/* fd4:inject:daily */
INSERT INTO finance_dashboard_daily (
    company_id, date, sales, cogs, opex, other_income, depreciation,
    sales_ic, cogs_ic, cash_bank_delta, ar_delta, ap_delta, ar_ic_delta,
    ap_ic_delta, other_current_assets_delta, other_current_liabilities_delta,
    other_current_assets_ic_delta, other_current_liabilities_ic_delta)
SELECT min(id), DATE '1900-01-01', 1.00,
       0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  FROM res_company"""

INJECT_EXPENSE = """/* fd4:inject:expense */
INSERT INTO finance_dashboard_expense_daily (company_id, account_id, date, amount)
SELECT (SELECT min(id) FROM res_company), (SELECT min(id) FROM account_account),
       DATE '1900-01-01', 1.00"""

INJECT_COVERAGE = """/* fd4:inject:coverage */
INSERT INTO finance_dashboard_coverage (
    company_id, covered_from, covered_to, last_refresh_at, last_refresh_ok)
VALUES (-1, DATE '1900-01-01', DATE '1900-01-01',
        TIMESTAMP '1900-01-01 00:00:00', false)"""


class Refused(Exception):
    """A precondition failed. Nothing has been written."""


class GateFailed(Exception):
    """The guard or a check failed, or a test expectation was not met."""


def out(*fields):
    print('|'.join(['FD4'] + [_clean(field) for field in fields]), flush=True)


def _clean(value):
    text = '' if value is None else str(value)
    return text.replace('|', '/').replace('\r', ' ').replace('\n', ' ')


def amount(value):
    """A gate amount as text with two decimals, as 06b/06c's ROUND(..., 2) means it.

    Odoo's cursor turns PostgreSQL numeric into Python float (sql_db.undecimalize),
    so 1.00 arrives as 1.0. Display and the L-B comparison only: PASS or FAIL is
    decided inside the SQL and never depends on this.
    """
    if value is None:
        return ''
    try:
        return str(Decimal(str(value)).quantize(Decimal('0.01')))
    except (InvalidOperation, ValueError):
        return str(value)


def describe(exc):
    lines = str(exc).strip().splitlines()
    code = getattr(exc, 'pgcode', None)
    prefix = type(exc).__name__ + (' ' + code if code else '')
    return prefix + ': ' + (lines[0] if lines else '')


def read_config():
    values = {key: os.environ.get(key, '') for key in REQUIRED}
    missing = [key for key in REQUIRED if not values[key]]
    if missing:
        raise Refused('missing instruction(s) ' + ', '.join(missing)
                      + ' - run this file only through 12_refresh.sh')
    if values['FD4_MODE'] not in MODES:
        raise Refused('unknown FD4_MODE ' + repr(values['FD4_MODE']))
    if values['FD4_INJECT'] not in INJECTS:
        raise Refused('unknown FD4_INJECT ' + repr(values['FD4_INJECT']))
    if not re.fullmatch(r'[1-9][0-9]{0,5}(ms|s|min)', values['FD4_LOCK_TIMEOUT']):
        raise Refused('invalid FD4_LOCK_TIMEOUT ' + repr(values['FD4_LOCK_TIMEOUT']))
    pins = {}
    for item in values['FD4_PINS'].split(';'):
        name, sep, digest = item.partition('=')
        if not sep or not name or name in pins \
                or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise Refused('malformed FD4_PINS entry ' + repr(item))
        pins[name] = digest
    return {
        'mode': values['FD4_MODE'],
        'inject': values['FD4_INJECT'],
        'dir': values['FD4_DIR'],
        'module_dir': values['FD4_MODULE_DIR'],
        'db': values['FD4_EXPECTED_DB'],
        'uuid': values['FD4_EXPECTED_UUID'],
        'postmaster_start': values['FD4_PRE_POSTMASTER_START'],
        'lock_timeout': values['FD4_LOCK_TIMEOUT'],
        'pins': pins,
    }


def check_identity(env, cfg):
    env.cr.execute(IDENTITY_SQL)
    isolation, database, uuid, started, statement_timeout, idle_timeout, \
        synchronous_commit = env.cr.fetchone()
    out('identity', isolation, database, uuid, started)
    out('session', 'statement_timeout=' + str(statement_timeout),
        'idle_in_transaction_session_timeout=' + str(idle_timeout),
        'synchronous_commit=' + str(synchronous_commit))
    problems = []
    if isolation != 'repeatable read':
        problems.append('isolation is ' + repr(isolation)
                        + ', not REPEATABLE READ - one snapshot is not guaranteed')
    if database != cfg['db']:
        problems.append('database is ' + repr(database) + ', expected ' + cfg['db'])
    if uuid != cfg['uuid']:
        problems.append('database.uuid is ' + repr(uuid) + ', expected ' + cfg['uuid'])
    if started != cfg['postmaster_start']:
        problems.append('cluster start time ' + str(started) + ' differs from the'
                        ' pre-check (' + cfg['postmaster_start'] + ') - the server'
                        ' restarted, or this is another cluster')
    if problems:
        raise Refused('; '.join(problems))


def _verify(cfg, key, path):
    pin = cfg['pins'].get(key)
    if pin is None:
        raise Refused('no approved hash supplied for ' + key)
    try:
        with open(path, 'rb') as handle:
            data = handle.read()
    except OSError as exc:
        raise Refused(key + ': cannot read ' + path + ' (' + describe(exc) + ')')
    digest = hashlib.sha256(data).hexdigest()
    out('file', key, digest, 'OK' if digest == pin else 'MISMATCH')
    if digest != pin:
        raise Refused(key + ' does not match its approved hash')
    return data


def check_files(env, cfg):
    function = getattr(type(env['finance.dashboard.daily']), 'refresh_full', None)
    code = getattr(function, '__code__', None)
    if code is None:
        raise Refused('finance.dashboard.daily has no refresh_full() - wrong module version')
    code_file = os.path.realpath(code.co_filename)
    module_dir = os.path.dirname(os.path.dirname(code_file))
    out('module', module_dir)
    if module_dir != os.path.realpath(cfg['module_dir']):
        raise Refused('Odoo loaded refresh_full() from ' + code_file
                      + ', not from the checked copy ' + cfg['module_dir'])
    if os.path.relpath(code_file, module_dir) != LAYER_FILE:
        raise Refused('refresh_full() is defined in ' + code_file
                      + ', expected ' + LAYER_FILE)
    stages = tuple(function.__globals__.get('SQL_STAGES', ()))
    if stages != STAGES:
        raise Refused('refresh_full() would run ' + repr(stages)
                      + ', expected ' + repr(STAGES))
    _verify(cfg, 'module/' + LAYER_FILE, code_file)
    for stage in STAGES:
        _verify(cfg, 'module/sql/' + stage, os.path.join(module_dir, 'sql', stage))
    texts = {}
    for name in (GUARD, CLEAR) + tuple(item[1] for item in GATE):
        data = _verify(cfg, 'folder/' + name, os.path.join(cfg['dir'], name))
        texts[name] = data.decode('utf-8')
    return texts


def set_lock_timeout(env, cfg):
    value = cfg['lock_timeout']        # validated in read_config: digits + unit
    env.cr.execute("/* fd4:lock */ SET LOCAL lock_timeout = '" + value + "'")
    env.cr.execute("/* fd4:lock */ SELECT current_setting('lock_timeout')")
    out('lock_timeout', env.cr.fetchone()[0])


def run_guard(env, texts):
    env.cr.execute(texts[GUARD])
    # The guard file holds two statements and the cursor returns the LAST one:
    # one row per unclassified account_type, so no row at all means PASS.
    rows = env.cr.fetchall()
    for row in rows:
        out('guard', 'UNCLASSIFIED', *row)
    if rows:
        raise GateFailed('account-type guard: ' + str(len(rows))
                         + ' unclassified account_type(s)')
    out('guard', 'PASS')


def layer_rows(env):
    env.cr.execute(ROWS_SQL)
    return tuple(int(value) for value in env.cr.fetchone())


def residue(env):
    env.cr.execute(RESIDUE_SQL)
    return tuple(int(value) for value in env.cr.fetchone())


def expect_residue(env, label, expected, refuse=False):
    got = residue(env)
    out('residue', label, *got)
    if got != expected:
        message = ('test rows ' + label + ': daily/expense/coverage = ' + str(got)
                   + ', expected ' + str(expected))
        if refuse:
            raise Refused(message + ' - existing rows would make the test unreadable')
        raise GateFailed(message)


def inject(env, when):
    expect_residue(env, 'before-inject', (0, 0, 0), refuse=(when == 'before-build'))
    env.cr.execute(INJECT_DAILY)
    env.cr.execute(INJECT_EXPENSE)
    expected = (1, 1, 0)
    if when == 'before-build':
        env.cr.execute(INJECT_COVERAGE)
        expected = (1, 1, 1)
    got = residue(env)
    out('inject', when, *got)
    if got != expected:
        raise RuntimeError('test rows were not inserted as expected: ' + str(got)
                           + ', expected ' + str(expected))


def clear(env, texts):
    out('rows', 'before-clear', *layer_rows(env))
    env.cr.execute(texts[CLEAR])
    after = layer_rows(env)
    out('rows', 'after-clear', *after)
    if (after[0], after[3], after[4]) != (0, 0, 0):
        raise RuntimeError('the clear left rows behind: daily=' + str(after[0])
                           + ' expense=' + str(after[3]) + ' coverage=' + str(after[4]))


def build(env):
    for stage, seconds in env['finance.dashboard.daily'].refresh_full():
        out('stage', stage, seconds)


def run_gate(env, texts):
    failures = []
    for label, name, expected in GATE:
        started = time.time()
        env.cr.execute(texts[name])
        rows = env.cr.fetchall()
        passed = 0
        for check, left, right, difference, status in rows:
            out('check', label, check, amount(left), amount(right), amount(difference), status)
            if status == 'PASS':
                passed += 1
            else:
                failures.append((label, check, amount(difference)))
        out('gate', label, str(passed) + '/' + str(len(rows)),
            'expected=' + str(expected), '{:.2f}s'.format(time.time() - started))
        if len(rows) != expected:
            failures.append((label, str(len(rows)) + ' rows', 'expected ' + str(expected)))
    return failures


def report_layer(env):
    out('rows', 'final', *layer_rows(env))
    env.cr.execute('/* fd4:stamp */ ' + STAMP_SQL)
    out('stamp', env.cr.fetchone()[0])


def _rollback(env):
    try:
        env.cr.rollback()
        out('rollback', 'DONE')
    except Exception as exc:     # the connection may be gone: PostgreSQL then
        out('rollback', 'ERROR', describe(exc))   # discards the transaction itself


def _end(started, *fields):
    out('elapsed', '{:.2f}s'.format(time.time() - started))
    out('outcome', *fields)


def finish(env, commit_allowed, started):
    if commit_allowed is not True:
        _rollback(env)
        _end(started, 'ROLLED_BACK', 'test', 'every check passed - a test mode never commits')
        return
    out('commit', 'ATTEMPTED')
    try:
        env.cr.commit()          # THE ONLY COMMIT IN THIS FILE
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        out('commit', 'ERROR', describe(exc))
        _rollback(env)
        _end(started, 'UNKNOWN', describe(exc))
        return
    out('commit', 'DONE')
    _end(started, 'COMMITTED')


def main(env):
    started = time.time()
    try:
        cfg = read_config()
    except Refused as exc:
        _rollback(env)
        _end(started, 'ROLLED_BACK', 'refused', exc)
        return
    commit_allowed = cfg['mode'] == 'live' and cfg['inject'] == 'none'
    out('start', 'mode=' + cfg['mode'], 'inject=' + cfg['inject'],
        'commit_allowed=' + ('yes' if commit_allowed else 'no'),
        'python=' + sys.version.split()[0])
    try:
        env.cr.rollback()                                        # step 0
        check_identity(env, cfg)                                 # step 1
        texts = check_files(env, cfg)                            # step 2
        set_lock_timeout(env, cfg)                               # step 3
        run_guard(env, texts)                                    # step 4
        if cfg['inject'] == 'before-build':
            inject(env, 'before-build')
        clear(env, texts)                                        # step 5
        if cfg['inject'] == 'before-build':
            expect_residue(env, 'after-clear', (0, 0, 0))
        build(env)                                               # step 6
        if cfg['inject'] == 'before-build':
            expect_residue(env, 'after-build', (0, 0, 0))
        if cfg['inject'] == 'after-build':
            inject(env, 'after-build')
        failures = run_gate(env, texts)                          # step 7
        report_layer(env)
        if cfg['inject'] == 'after-build':
            got = set(failures)
            out('expected-failures', 'match' if got == L_B_EXPECTED else 'mismatch',
                'got=' + '; '.join(sorted(' '.join(item) for item in got)))
        if failures:
            raise GateFailed(str(len(failures)) + ' check(s) failed: '
                             + '; '.join(' '.join(item) for item in failures))
    except Refused as exc:
        _rollback(env)
        _end(started, 'ROLLED_BACK', 'refused', exc)
        return
    except GateFailed as exc:
        _rollback(env)
        _end(started, 'ROLLED_BACK', 'gate', exc)
        return
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        _rollback(env)
        _end(started, 'ROLLED_BACK', 'error', describe(exc))
        return
    finish(env, commit_allowed, started)                         # step 8


if __name__ == '__main__':
    main(env)  # noqa: F821 - odoo shell provides `env`
