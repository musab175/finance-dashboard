#!/usr/bin/env python3
# =============================================================================
# 12a_refresh_transaction_test.py - controlled tests for the Section 4 driver,
# 12a_refresh_transaction.py. 2026-10-13.
#
# NO DATABASE, NO ODOO, NO SUDO. The driver's text is exec'd exactly the way
# `odoo shell` runs a file piped to it - with `env` in its globals - but `env`
# is a stand-in: its cursor records every statement and answers with made-up
# results, refresh_full() is a stand-in, and the module copy is a temporary
# folder.
#
# WHAT IT PROVES
#   1. Requirement 7: no test mode can commit. Every combination of 10 mode
#      values and 9 inject values (valid, misspelt, padded, empty and missing)
#      with 16 simulated outcomes is run. commit() is reached exactly when
#      mode=live, inject=none and every check passed - never otherwise.
#   2. Every run prints exactly one outcome line, as its last FD4 line, and a
#      run that did not reach commit() rolls back after its last write.
#   3. Nothing is written before the guard has passed, and nothing at all when
#      a precondition fails.
#   4. Every INSERT, UPDATE or DELETE the driver issues targets one of the five
#      reporting tables, so test rows cannot reach the ledger; no statement
#      creates, drops, alters, truncates or vacuums anything.
#   5. The driver opens files for reading only and never calls sys.exit.
#   6. Named cases, line by line: L-A, L-B, each refusal and each outcome.
#
# Needs in the same folder: 12a_refresh_transaction.py,
# 12b_clear_upsert_tables.sql, 00_guard_account_types.sql,
# 06b_validate_live_inline.sql and 06c_validate_cross_table.sql. The SQL files
# are only read, to recognise them; none is executed.
#
# Usage:  python3 12a_refresh_transaction_test.py    exit 0 only if all pass
# =============================================================================
import contextlib
import hashlib
import io
import itertools
import os
import re
import shutil
import sys
import tempfile
import tokenize
from decimal import Decimal

HERE = os.path.dirname(os.path.abspath(__file__))
DRIVER_PATH = os.path.join(HERE, '12a_refresh_transaction.py')
FOLDER_FILES = ('00_guard_account_types.sql', '12b_clear_upsert_tables.sql',
                '06b_validate_live_inline.sql', '06c_validate_cross_table.sql')
STAGES = ('02_backfill_daily.sql', '03_backfill_arap.sql',
          '04_backfill_expense_and_derived.sql')
TABLES = {'finance_dashboard_daily', 'finance_dashboard_arap_daily',
          'finance_dashboard_aging_daily', 'finance_dashboard_expense_daily',
          'finance_dashboard_coverage'}
UUID = '629148b0-9f15-11ee-bf49-2569bf801689'
START = '2026-10-13T05:12:34.567890Z'
STAMP = '2026-10-13 09:00:00.123456'
WARM = (8756, 506202, 39805, 17747, 9)
MEASURES_06B = ('ap', 'ap_ic', 'ar', 'ar_ic', 'cash', 'cogs', 'cogs_ic',
                'depreciation', 'oca', 'oca_ic', 'ocl', 'ocl_ic', 'opex',
                'other_income', 'sales', 'sales_ic')
INVARIANTS_06C = ('aging.ap   = arap.ap non-IC', 'aging.ar   = arap.ar non-IC',
                  'arap.ap    = daily.ap_delta', 'arap.ap_ic = daily.ap_ic_delta',
                  'arap.ar    = daily.ar_delta', 'arap.ar_ic = daily.ar_ic_delta',
                  'expense    = opex+cogs+dep')
WRITE_KINDS = {'inject:daily', 'inject:expense', 'inject:coverage',
               'file:12b_clear_upsert_tables.sql', 'BUILD'}
MISSING = object()

with open(DRIVER_PATH) as handle:
    DRIVER_SRC = handle.read()
DRIVER_CODE = compile(DRIVER_SRC, DRIVER_PATH, 'exec')
FOLDER_TEXT = {}
for _name in FOLDER_FILES:
    with open(os.path.join(HERE, _name), encoding='utf-8') as handle:
        FOLDER_TEXT[_name] = handle.read()

FAKE_LAYER_SRC = (
    "# stand-in for models/finance_dashboard_layer.py\n"
    "SQL_STAGES = " + repr(STAGES) + "\n\n\n"
    "class FakeDaily:\n"
    "    def refresh_full(self):\n"
    "        return _build_hook()\n")


class FakeDbError(Exception):
    def __init__(self, message, pgcode=None):
        super().__init__(message)
        self.pgcode = pgcode


class Scenario:
    """What the stand-in database and Odoo do in one run."""

    def __init__(self, **kw):
        self.warm = kw.pop('warm', True)
        self.identity = kw.pop('identity', ('repeatable read', 'gftuae', UUID, START,
                                            '0', '0', 'on'))
        self.guard_rows = kw.pop('guard_rows', [])
        self.fail_06b = kw.pop('fail_06b', None)
        self.fail_06c = kw.pop('fail_06c', None)
        self.short_06b = kw.pop('short_06b', False)
        self.null_06b = kw.pop('null_06b', False)
        self.build_error = kw.pop('build_error', None)
        self.build_leaves_residue = kw.pop('build_leaves_residue', False)
        self.build_empty = kw.pop('build_empty', False)
        self.commit_error = kw.pop('commit_error', False)
        self.rollback_error = kw.pop('rollback_error', False)
        self.preexisting_residue = kw.pop('preexisting_residue', False)
        self.clear_broken = kw.pop('clear_broken', False)
        self.no_refresh_full = kw.pop('no_refresh_full', False)
        self.stages = kw.pop('stages', STAGES)
        # Odoo's cursor returns numeric as float (sql_db.undecimalize); plain psycopg2
        # returns Decimal. The default is Odoo's behaviour.
        self.numeric = kw.pop('numeric', float)
        if kw:
            raise TypeError('unknown scenario keys: ' + ', '.join(kw))


class Layer:
    def __init__(self, warm):
        self.rows = list(WARM if warm else (0, 0, 0, 0, 0))
        self.res = [0, 0, 0]        # daily 1900-01-01, expense 1900-01-01, coverage -1


class FakeCursor:
    def __init__(self, sc, layer):
        self.sc = sc
        self.layer = layer
        self.log = []
        self.commits = 0
        self.rollbacks = 0
        self.result = []

    def execute(self, query, params=None):
        if params is not None:
            raise AssertionError('the driver passed parameters to cr.execute()')
        kind = classify(query)
        self.log.append((kind, query))
        sc, layer = self.sc, self.layer
        self.result = []
        if kind == 'identity':
            self.result = [sc.identity]
        elif kind == 'lock':
            if 'SET LOCAL' in query:
                if not re.search(r"SET LOCAL lock_timeout = '[1-9][0-9]*(ms|s|min)'$", query):
                    raise AssertionError('unexpected lock statement: ' + query)
            else:
                self.result = [('1min',)]
        elif kind == 'rows':
            self.result = [tuple(layer.rows)]
        elif kind == 'residue':
            self.result = [tuple(layer.res)]
        elif kind == 'stamp':
            self.result = [(STAMP,)]
        elif kind == 'inject:daily':
            layer.rows[0] += 1
            layer.res[0] += 1
        elif kind == 'inject:expense':
            layer.rows[3] += 1
            layer.res[1] += 1
        elif kind == 'inject:coverage':
            layer.rows[4] += 1
            layer.res[2] += 1
        elif kind == 'file:00_guard_account_types.sql':
            self.result = list(sc.guard_rows)
        elif kind == 'file:12b_clear_upsert_tables.sql':
            if not sc.clear_broken:
                layer.rows[0] = layer.rows[3] = layer.rows[4] = 0
                layer.res = [0, 0, 0]
        elif kind == 'file:06b_validate_live_inline.sql':
            self.result = gate_06b(sc, layer)
        elif kind == 'file:06c_validate_cross_table.sql':
            self.result = gate_06c(sc, layer)
        else:
            raise AssertionError('unexpected SQL from the driver: ' + query[:80])

    def fetchall(self):
        return list(self.result)

    def fetchone(self):
        return self.result[0] if self.result else None

    def commit(self):
        self.commits += 1
        self.log.append(('COMMIT', ''))
        if self.sc.commit_error:
            raise FakeDbError('server closed the connection unexpectedly', '08006')

    def rollback(self):
        self.rollbacks += 1
        self.log.append(('ROLLBACK', ''))
        if self.sc.rollback_error and any(k == 'BUILD' for k, _ in self.log):
            raise FakeDbError('connection already closed')


class FakeEnv:
    def __init__(self, cursor, model):
        self.cr = cursor
        self._model = model

    def __getitem__(self, name):
        if name != 'finance.dashboard.daily':
            raise AssertionError('the driver asked for model ' + name)
        return self._model


def classify(query):
    match = re.match(r'\s*/\* fd4:([a-z:]+) \*/', query)
    if match:
        return match.group(1)
    for name, text in FOLDER_TEXT.items():
        if query == text:
            return 'file:' + name
    return 'UNKNOWN'


def gate_06b(sc, layer):
    rows = []
    for measure in MEASURES_06B:
        if layer.rows[0] == 0:                     # empty table: SUM is NULL
            rows.append((measure, Decimal('5.00'), None, None, 'FAIL'))
            continue
        difference = Decimal('0.00')
        if measure == 'sales':
            difference += Decimal('1.00') * layer.res[0]
        if sc.fail_06b == measure:
            difference += Decimal('0.01')
        rows.append((measure, Decimal('100.00'), Decimal('100.00') + difference,
                     difference, 'PASS' if difference == 0 else 'FAIL'))
    if sc.null_06b:
        rows[0] = (rows[0][0], Decimal('1.00'), None, None, 'FAIL')
    if sc.short_06b:
        rows = rows[:15]
    return [as_numeric(sc, row) for row in rows]


def gate_06c(sc, layer):
    rows = []
    for invariant in INVARIANTS_06C:
        difference = Decimal('0.00')
        if invariant.startswith('expense'):
            difference += Decimal('1.00') * layer.res[1]
        if sc.fail_06c == invariant:
            difference += Decimal('0.01')
        rows.append((invariant, Decimal('7.00') + difference, Decimal('7.00'),
                     difference, 'PASS' if difference == 0 else 'FAIL'))
    return [as_numeric(sc, row) for row in rows]


def as_numeric(sc, row):
    """Amounts as the cursor delivers them: float under Odoo, Decimal under plain psycopg2."""
    return tuple(sc.numeric(v) if isinstance(v, Decimal) else v for v in row)


class Fixture:
    """Temporary module copy and Section 4 folder, with their pins."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix='fd4_driver_test_')
        self.module = os.path.join(self.root, 'addons', 'odoo17_finance_dashboard')
        os.makedirs(os.path.join(self.module, 'models'))
        os.makedirs(os.path.join(self.module, 'sql'))
        self.layer_file = os.path.join(self.module, 'models', 'finance_dashboard_layer.py')
        with open(self.layer_file, 'w') as handle:
            handle.write(FAKE_LAYER_SRC)
        for stage in STAGES:
            with open(os.path.join(self.module, 'sql', stage), 'w') as handle:
                handle.write('-- stand-in for ' + stage + '\n')
        self.folder = os.path.join(self.root, 'section4')
        os.makedirs(self.folder)
        for name in FOLDER_FILES:
            shutil.copy(os.path.join(HERE, name), os.path.join(self.folder, name))
        self.pins = {}
        self.pins['module/models/finance_dashboard_layer.py'] = sha(self.layer_file)
        for stage in STAGES:
            self.pins['module/sql/' + stage] = sha(os.path.join(self.module, 'sql', stage))
        for name in FOLDER_FILES:
            self.pins['folder/' + name] = sha(os.path.join(self.folder, name))

    def folder_without(self, name):
        path = os.path.join(self.root, 'without_' + name)
        if not os.path.isdir(path):
            shutil.copytree(self.folder, path)
            os.remove(os.path.join(path, name))
        return path

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


def sha(path):
    with open(path, 'rb') as handle:
        return hashlib.sha256(handle.read()).hexdigest()


class Result:
    def __init__(self, stdout, stderr, cursor, opened, exited):
        self.stdout = stdout
        self.stderr = stderr
        self.cursor = cursor
        self.opened = opened
        self.exited = exited
        self.lines = [line for line in stdout.splitlines() if line.startswith('FD4|')]
        outcomes = [line for line in self.lines if line.startswith('FD4|outcome|')]
        self.outcome = outcomes[-1] if outcomes else ''
        self.n_outcomes = len(outcomes)
        self.kinds = [kind for kind, _ in cursor.log]


def base_env(fx, **overrides):
    values = {
        'FD4_MODE': 'live', 'FD4_INJECT': 'none', 'FD4_DIR': fx.folder,
        'FD4_MODULE_DIR': fx.module, 'FD4_EXPECTED_DB': 'gftuae',
        'FD4_EXPECTED_UUID': UUID, 'FD4_PRE_POSTMASTER_START': START,
        'FD4_LOCK_TIMEOUT': '60s',
        'FD4_PINS': ';'.join(k + '=' + v for k, v in fx.pins.items()),
    }
    values.update(overrides)
    return values


def run(fx, values, sc):
    layer = Layer(sc.warm)
    if sc.preexisting_residue:              # a real row already on 1900-01-01
        layer.rows[0] += 1
        layer.res[0] = 1
    cursor = FakeCursor(sc, layer)

    def build_hook():
        cursor.log.append(('BUILD', ''))
        if sc.build_error:
            raise sc.build_error
        layer.rows = [0, 0, 0, 0, 0] if sc.build_empty else list(WARM)
        if sc.build_leaves_residue:
            layer.res[0] = 1
        return [(stage, 1.25) for stage in STAGES]

    namespace = {'_build_hook': build_hook}
    exec(compile(FAKE_LAYER_SRC, fx.layer_file, 'exec'), namespace)
    namespace['SQL_STAGES'] = sc.stages
    model_class = namespace['FakeDaily']
    if sc.no_refresh_full:
        model_class = type('FakeDailyWithoutRefresh', (), {})
    fake_env = FakeEnv(cursor, model_class())

    opened = []

    def guarded_open(path, mode='r', *args, **kwargs):
        opened.append((path, mode))
        if any(flag in mode for flag in 'wax+'):
            raise AssertionError('the driver opened ' + str(path) + ' for writing')
        return open(path, mode, *args, **kwargs)

    saved = {key: value for key, value in os.environ.items() if key.startswith('FD4_')}
    for key in saved:
        del os.environ[key]
    for key, value in values.items():
        if value is not MISSING:
            os.environ[key] = value
    stdout, stderr = io.StringIO(), io.StringIO()
    exited = None
    try:
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            exec(DRIVER_CODE, {'__name__': '__main__', 'env': fake_env, 'open': guarded_open})
    except SystemExit as exc:
        exited = exc
    finally:
        for key in [key for key in os.environ if key.startswith('FD4_')]:
            del os.environ[key]
        os.environ.update(saved)
    return Result(stdout.getvalue(), stderr.getvalue(), cursor, opened, exited)


def strip_sql_comments(query):
    query = re.sub(r'/\*.*?\*/', ' ', query, flags=re.S)
    return re.sub(r'--[^\n]*', ' ', query)


def write_targets(query):
    return re.findall(r'\b(?:INSERT\s+INTO|DELETE\s+FROM|UPDATE)\s+([A-Za-z_][\w.]*)',
                      strip_sql_comments(query), flags=re.I)


def invariants(res, commit_expected):
    """Properties every run must have, whatever the inputs."""
    problems = []
    if res.exited is not None:
        problems.append('sys.exit was called')
    if res.n_outcomes != 1 or not res.lines or res.lines[-1] != res.outcome:
        problems.append('not exactly one outcome line as the last FD4 line')
    if 'UNKNOWN' in res.kinds:
        problems.append('the driver issued unexpected SQL')
    if res.cursor.commits != (1 if commit_expected else 0):
        problems.append('commit() reached %d time(s), expected %d'
                        % (res.cursor.commits, 1 if commit_expected else 0))
    writes = [i for i, kind in enumerate(res.kinds) if kind in WRITE_KINDS]
    if writes:
        guard = [i for i, kind in enumerate(res.kinds)
                 if kind == 'file:00_guard_account_types.sql']
        if not guard or writes[0] < guard[0]:
            problems.append('a write came before the guard')
        if res.cursor.commits == 0 and 'ROLLBACK' not in res.kinds[writes[-1] + 1:]:
            problems.append('no rollback after the last write')
    for _, query in res.cursor.log:
        for target in write_targets(query):
            if target not in TABLES:
                problems.append('write to a non-reporting table: ' + target)
        if re.search(r'\b(TRUNCATE|DROP|ALTER|CREATE|VACUUM|GRANT|REVOKE|COPY)\b',
                      strip_sql_comments(query), flags=re.I):
            problems.append('forbidden statement: ' + query[:60])
    if res.cursor.commits == 0 and not res.outcome.startswith('FD4|outcome|ROLLED_BACK|'):
        problems.append('no commit attempted, yet the outcome is ' + res.outcome)
    if res.outcome == 'FD4|outcome|COMMITTED' and not commit_expected:
        problems.append('COMMITTED reported where no commit is allowed')
    return problems


# ---- named cases --------------------------------------------------------------
PASSED = []
FAILED = []


def check(name, condition, detail=''):
    (PASSED if condition else FAILED).append((name, detail))
    print(('PASS  ' if condition else 'FAIL  ') + name + ('  - ' + detail if detail and not condition else ''))


def named(fx, name, values, sc, commit_expected, outcome_prefix, must=(), must_not=(),
          order=None):
    res = run(fx, values, sc)
    problems = invariants(res, commit_expected)
    if not res.outcome.startswith(outcome_prefix):
        problems.append('outcome ' + repr(res.outcome) + ', expected ' + repr(outcome_prefix))
    for line in must:
        if not any(got == line or got.startswith(line) for got in res.lines):
            problems.append('missing line ' + repr(line))
    for line in must_not:
        if any(got == line or got.startswith(line) for got in res.lines):
            problems.append('unexpected line ' + repr(line))
    if order:
        positions = []
        for kind in order:
            if kind not in res.kinds:
                problems.append('statement ' + kind + ' never ran')
                break
            positions.append(res.kinds.index(kind))
        else:
            if positions != sorted(positions):
                problems.append('statements out of order: ' + ' -> '.join(order))
    check(name, not problems, '; '.join(problems) + ('\n' + res.stdout if problems else ''))
    return res


def named_cases(fx):
    S = Scenario
    base = base_env(fx)
    order_live = ['identity', 'lock', 'file:00_guard_account_types.sql',
                  'file:12b_clear_upsert_tables.sql', 'BUILD',
                  'file:06b_validate_live_inline.sql', 'file:06c_validate_cross_table.sql',
                  'stamp', 'COMMIT']
    print('--- success and the test modes ---')
    named(fx, 'live, every check passes -> COMMITTED', base, S(), True,
          'FD4|outcome|COMMITTED',
          must=('FD4|start|mode=live|inject=none|commit_allowed=yes', 'FD4|guard|PASS',
                'FD4|gate|06b|16/16|expected=16', 'FD4|gate|06c|7/7|expected=7',
                'FD4|commit|ATTEMPTED', 'FD4|commit|DONE', 'FD4|stamp|' + STAMP,
                'FD4|rows|final|8756|506202|39805|17747|9'),
          order=order_live)
    named(fx, 'live, cold build into empty tables -> COMMITTED', base, S(warm=False), True,
          'FD4|outcome|COMMITTED', must=('FD4|rows|before-clear|0|0|0|0|0',))
    named(fx, 'rollback-only, every check passes -> never commits', dict(base, FD4_MODE='rollback-only'),
          S(), False, 'FD4|outcome|ROLLED_BACK|test|',
          must=('FD4|start|mode=rollback-only|inject=none|commit_allowed=no',
                'FD4|gate|06b|16/16', 'FD4|gate|06c|7/7'), must_not=('FD4|commit|',))
    named(fx, 'L-A before-build: test rows cleared, 23/23, never commits',
          dict(base, FD4_MODE='rollback-only', FD4_INJECT='before-build'), S(), False,
          'FD4|outcome|ROLLED_BACK|test|',
          must=('FD4|residue|before-inject|0|0|0', 'FD4|inject|before-build|1|1|1',
                'FD4|residue|after-clear|0|0|0', 'FD4|residue|after-build|0|0|0',
                'FD4|gate|06b|16/16', 'FD4|gate|06c|7/7'),
          must_not=('FD4|commit|',),
          order=['file:00_guard_account_types.sql', 'inject:daily', 'inject:expense',
                 'inject:coverage', 'file:12b_clear_upsert_tables.sql', 'BUILD',
                 'file:06b_validate_live_inline.sql'])
    res = named(fx, 'L-B after-build: exactly the two expected failures, rolled back',
                dict(base, FD4_MODE='rollback-only', FD4_INJECT='after-build'), S(), False,
                'FD4|outcome|ROLLED_BACK|gate|',
                must=('FD4|inject|after-build|1|1|0', 'FD4|expected-failures|match|',
                      'FD4|check|06b|sales|100.00|101.00|1.00|FAIL',
                      'FD4|check|06c|expense    = opex+cogs+dep|8.00|7.00|1.00|FAIL',
                      'FD4|gate|06b|15/16', 'FD4|gate|06c|6/7'),
                must_not=('FD4|commit|',),
                order=['BUILD', 'inject:daily', 'inject:expense',
                       'file:06b_validate_live_inline.sql'])
    fails = [line for line in res.lines if line.startswith('FD4|check|') and line.endswith('|FAIL')]
    check('L-B prints exactly two FAIL check lines', len(fails) == 2, str(fails))
    named(fx, 'L-B with Decimal amounts (plain psycopg2) -> still match',
          dict(base, FD4_MODE='rollback-only', FD4_INJECT='after-build'), S(numeric=Decimal), False,
          'FD4|outcome|ROLLED_BACK|gate|', must=('FD4|expected-failures|match|',
                                                 'FD4|check|06b|sales|100.00|101.00|1.00|FAIL'))
    named(fx, 'L-B with one extra failure -> mismatch marker, still gate',
          dict(base, FD4_MODE='rollback-only', FD4_INJECT='after-build'),
          S(fail_06c='arap.ar    = daily.ar_delta'), False, 'FD4|outcome|ROLLED_BACK|gate|',
          must=('FD4|expected-failures|mismatch|',))
    named(fx, 'L-A: a stale test row survives the build -> gate',
          dict(base, FD4_MODE='rollback-only', FD4_INJECT='before-build'),
          S(build_leaves_residue=True), False, 'FD4|outcome|ROLLED_BACK|gate|test rows after-build')
    named(fx, 'L-A: rows already on 1900-01-01 -> refused before any write',
          dict(base, FD4_MODE='rollback-only', FD4_INJECT='before-build'),
          S(preexisting_residue=True), False, 'FD4|outcome|ROLLED_BACK|',
          must_not=('FD4|inject|',))
    named(fx, 'contradiction: live + before-build -> treated as a test, never commits',
          dict(base, FD4_INJECT='before-build'), S(), False, 'FD4|outcome|ROLLED_BACK|test|',
          must=('FD4|start|mode=live|inject=before-build|commit_allowed=no',))
    named(fx, 'contradiction: live + after-build -> never commits',
          dict(base, FD4_INJECT='after-build'), S(), False, 'FD4|outcome|ROLLED_BACK|gate|')

    print('--- guard and gate failures: rolled back ---')
    named(fx, 'guard: unclassified account type -> gate, nothing written', base,
          S(guard_rows=[('asset_prepayments', 1, '1234', '1234')]), False,
          'FD4|outcome|ROLLED_BACK|gate|account-type guard',
          must=('FD4|guard|UNCLASSIFIED|asset_prepayments|1|1234|1234',),
          must_not=('FD4|rows|before-clear',))
    named(fx, '06b: one measure 0.01 off -> gate', base, S(fail_06b='ar'), False,
          'FD4|outcome|ROLLED_BACK|gate|', must=('FD4|check|06b|ar|100.00|100.01|0.01|FAIL',))
    named(fx, '06c: one invariant off -> gate', base,
          S(fail_06c='aging.ar   = arap.ar non-IC'), False, 'FD4|outcome|ROLLED_BACK|gate|')
    named(fx, '06b: 15 rows instead of 16 -> gate', base, S(short_06b=True), False,
          'FD4|outcome|ROLLED_BACK|gate|', must=('FD4|gate|06b|15/15|expected=16',))
    named(fx, '06b: NULL difference -> gate', base, S(null_06b=True), False,
          'FD4|outcome|ROLLED_BACK|gate|')
    named(fx, 'empty build: NULL everywhere -> gate', base, S(build_empty=True), False,
          'FD4|outcome|ROLLED_BACK|gate|')

    print('--- technical failures: rolled back ---')
    named(fx, 'build raises -> error', base, S(build_error=FakeDbError('division by zero', '22012')),
          False, 'FD4|outcome|ROLLED_BACK|error|FakeDbError 22012: division by zero')
    named(fx, 'lock timeout during the build -> error 55P03', base,
          S(build_error=FakeDbError('canceling statement due to lock timeout', '55P03')),
          False, 'FD4|outcome|ROLLED_BACK|error|FakeDbError 55P03')
    named(fx, 'the clear leaves rows -> error', base, S(clear_broken=True), False,
          'FD4|outcome|ROLLED_BACK|error|RuntimeError: the clear left rows behind')
    named(fx, 'rollback itself fails after an error -> still one outcome', base,
          S(build_error=FakeDbError('boom'), rollback_error=True), False,
          'FD4|outcome|ROLLED_BACK|error|', must=('FD4|rollback|ERROR|',))

    print('--- commit outcome not confirmed ---')
    named(fx, 'commit raises -> UNKNOWN, never DONE', base, S(commit_error=True), True,
          'FD4|outcome|UNKNOWN|FakeDbError 08006',
          must=('FD4|commit|ATTEMPTED', 'FD4|commit|ERROR|'), must_not=('FD4|commit|DONE',))

    print('--- identity: refused, nothing written ---')
    for label, identity in (
            ('isolation READ COMMITTED', ('read committed', 'gftuae', UUID, START, '0', '0', 'on')),
            ('another database', ('repeatable read', 'postgres', UUID, START, '0', '0', 'on')),
            ('another uuid', ('repeatable read', 'gftuae', 'x-other-uuid', START, '0', '0', 'on')),
            ('cluster restarted', ('repeatable read', 'gftuae', UUID,
                                   '2026-10-13T14:02:11.000000Z', '0', '0', 'on'))):
        named(fx, 'identity: ' + label + ' -> refused', base, S(identity=identity), False,
              'FD4|outcome|ROLLED_BACK|refused|', must_not=('FD4|rows|',))

    print('--- files: refused, nothing written ---')
    for key in fx.pins:
        pins = dict(fx.pins, **{key: '0' * 64})
        named(fx, 'pin mismatch: ' + key + ' -> refused',
              dict(base, FD4_PINS=';'.join(k + '=' + v for k, v in pins.items())), S(), False,
              'FD4|outcome|ROLLED_BACK|refused|' + key + ' does not match')
    for name in FOLDER_FILES:
        named(fx, 'missing in the Section 4 folder: ' + name + ' -> refused',
              dict(base, FD4_DIR=fx.folder_without(name)), S(), False,
              'FD4|outcome|ROLLED_BACK|refused|folder/' + name + ': cannot read')
    named(fx, 'a pin not supplied -> refused',
          dict(base, FD4_PINS=';'.join(k + '=' + v for k, v in fx.pins.items()
                                       if k != 'folder/06c_validate_cross_table.sql')),
          S(), False, 'FD4|outcome|ROLLED_BACK|refused|no approved hash supplied')
    named(fx, 'Odoo loaded another module copy -> refused',
          dict(base, FD4_MODULE_DIR=os.path.join(fx.root, 'elsewhere')), S(), False,
          'FD4|outcome|ROLLED_BACK|refused|Odoo loaded refresh_full() from')
    named(fx, 'refresh_full() would run other stages -> refused', base,
          S(stages=('02_backfill_daily.sql', '03_backfill_arap.sql')), False,
          'FD4|outcome|ROLLED_BACK|refused|refresh_full() would run')
    named(fx, 'no refresh_full() on the model -> refused', base, S(no_refresh_full=True), False,
          'FD4|outcome|ROLLED_BACK|refused|finance.dashboard.daily has no refresh_full()')

    print('--- instructions: refused before the transaction ---')
    for key in base:
        named(fx, key + ' missing -> refused', dict(base, **{key: MISSING}), S(), False,
              'FD4|outcome|ROLLED_BACK|refused|missing instruction(s) ' + key,
              must_not=('FD4|start|',))
    named(fx, 'lock timeout carrying SQL -> refused',
          dict(base, FD4_LOCK_TIMEOUT="60s'; DROP TABLE account_move_line; --"), S(), False,
          'FD4|outcome|ROLLED_BACK|refused|invalid FD4_LOCK_TIMEOUT')
    named(fx, 'malformed pins -> refused', dict(base, FD4_PINS='folder/06b=nothex'), S(), False,
          'FD4|outcome|ROLLED_BACK|refused|malformed FD4_PINS entry')


def property_test(fx):
    """Requirement 7: commit() is reached only for live + none + all checks pass."""
    S = Scenario
    modes = ['live', 'rollback-only', 'LIVE', 'Live', 'live ', ' live', 'commit',
             'rollback_only', '', MISSING]
    injects = ['none', 'before-build', 'after-build', 'None', 'NONE', 'before',
               'after-build ', '', MISSING]
    outcomes = {
        'pass': S(),
        'guard-fail': S(guard_rows=[('asset_prepayments', 1, '1', '1')]),
        '06b-fail': S(fail_06b='opex'),
        '06c-fail': S(fail_06c='expense    = opex+cogs+dep'),
        '06b-short': S(short_06b=True),
        '06b-null': S(null_06b=True),
        'build-error': S(build_error=FakeDbError('boom', 'XX000')),
        'lock-timeout': S(build_error=FakeDbError('lock timeout', '55P03')),
        'commit-error': S(commit_error=True),
        'identity-uuid': S(identity=('repeatable read', 'gftuae', 'other', START, '0', '0', 'on')),
        'identity-start': S(identity=('repeatable read', 'gftuae', UUID, 'x', '0', '0', 'on')),
        'identity-isolation': S(identity=('read committed', 'gftuae', UUID, START, '0', '0', 'on')),
        'clear-broken': S(clear_broken=True),
        'stale-residue': S(build_leaves_residue=True),
        'pin-mismatch': None,
        'module-dir': None,
    }
    total = bad = 0
    for mode, inject_value, (label, sc) in itertools.product(modes, injects, outcomes.items()):
        values = base_env(fx, FD4_MODE=mode, FD4_INJECT=inject_value)
        if label == 'pin-mismatch':
            sc = S()
            pins = dict(fx.pins, **{'module/sql/03_backfill_arap.sql': 'f' * 64})
            values['FD4_PINS'] = ';'.join(k + '=' + v for k, v in pins.items())
        elif label == 'module-dir':
            sc = S()
            values['FD4_MODULE_DIR'] = os.path.join(fx.root, 'elsewhere')
        allowed = mode == 'live' and inject_value == 'none' and label in ('pass', 'commit-error')
        res = run(fx, values, sc)
        problems = invariants(res, allowed)
        total += 1
        if problems:
            bad += 1
            if bad <= 5:
                print('FAIL  property mode=%r inject=%r outcome=%s: %s'
                      % (mode if mode is not MISSING else 'MISSING',
                         inject_value if inject_value is not MISSING else 'MISSING',
                         label, '; '.join(problems)))
    check('requirement 7 property: %d combinations, commit reached only for '
          'live + none + all checks passing' % total, bad == 0, '%d combination(s) failed' % bad)


def static_checks():
    """The source itself: one commit call, no exit, no VACUUM, no percent sign in SQL."""
    names, strings = [], []
    with open(DRIVER_PATH, 'rb') as handle:
        tokens = list(tokenize.tokenize(handle.readline))
    for i, token in enumerate(tokens):
        if token.type == tokenize.NAME:
            names.append((token.string, tokens[i - 1].string if i else ''))
        elif token.type == tokenize.STRING:
            strings.append(token.string)
    commits = [n for n, before in names if n == 'commit' and before == '.']
    check('static: exactly one .commit( call in the driver', len(commits) == 1, str(len(commits)))
    check('static: no exit / _exit / subprocess / system in the driver',
          not any(n in ('exit', '_exit', 'subprocess', 'system', 'Popen') for n, _ in names))
    check('static: no VACUUM in any string of the driver',
          not any('VACUUM' in s.upper() for s in strings))
    sql_strings = [s for s in strings if re.search(r'\b(SELECT|INSERT|SET LOCAL)\b', s)]
    check('static: no percent sign in any SQL string of the driver',
          not any('%' in s for s in sql_strings))
    stamp = "SELECT COALESCE(to_char(max(last_refresh_at), 'YYYY-MM-DD HH24:MI:SS.US'), '') FROM finance_dashboard_coverage"
    check('static: STAMP_SQL is the agreed text', stamp in DRIVER_SRC)
    for name in FOLDER_FILES:
        check('static: no percent sign in ' + name, '%' not in FOLDER_TEXT[name])


def main():
    fx = Fixture()
    try:
        print('=== 12a_refresh_transaction.py - controlled tests (no database, no Odoo) ===')
        print('python ' + sys.version.split()[0])
        static_checks()
        named_cases(fx)
        print('--- requirement 7: every combination ---')
        property_test(fx)
    finally:
        fx.cleanup()
    print()
    print('%d checks: %d PASS, %d FAIL' % (len(PASSED) + len(FAILED), len(PASSED), len(FAILED)))
    return 0 if not FAILED else 1


if __name__ == '__main__':
    sys.exit(main())
