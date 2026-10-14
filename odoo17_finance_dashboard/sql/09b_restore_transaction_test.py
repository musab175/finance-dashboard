#!/usr/bin/env python3
# =============================================================================
# 09b_restore_transaction_test.py - controlled tests for the Section 5 driver,
# 09b_restore_transaction.py. 2026-10-14.
#
# NO DATABASE, NO SUDO. The driver's text is compiled and run, and main() is
# handed a stand-in connection: its cursor records every statement and every
# COPY and answers with made-up results. The plan and the five data files are
# written to a temporary folder for each run.
#
# WHAT IT PROVES
#   1. No test can commit. Every combination of 10 FD5_MODE values (valid,
#      misspelt, padded, empty, missing) with 13 simulated outcomes is run:
#      commit() is reached exactly when FD5_MODE=live and every step passed.
#   2. Every run prints exactly one outcome line, as its last FD5 line, and a
#      run that opened a connection but did not commit rolls back after its
#      last statement.
#   3. Nothing is written before the clear, and nothing at all when a
#      precondition fails.
#   4. The only writes are the clear (09d) and COPY ... FROM STDIN into the
#      five reporting tables with the record's column list. No statement of the
#      driver's own sets a sequence, analyses, vacuums, truncates, inserts,
#      updates or changes the schema.
#   5. The driver opens files for reading only, never calls sys.exit, and has
#      exactly one commit() call.
#   6. content() equals `LC_ALL=C sort | sha256sum`, the hash 12d and 09a record.
#   7. Named cases, line by line: each refusal, each failed comparison or
#      check, each outcome.
#
# Needs in the same folder: 09b_restore_transaction.py, 09d_clear_all_tables.sql,
# 06b_validate_live_inline.sql, 06c_validate_cross_table.sql. The SQL files are
# only read, to recognise them; none is executed.
#
# Usage:  python3 09b_restore_transaction_test.py    exit 0 only if all pass
# =============================================================================
import contextlib
import hashlib
import io
import itertools
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize
from decimal import Decimal

HERE = os.path.dirname(os.path.abspath(__file__))
DRIVER_PATH = os.path.join(HERE, '09b_restore_transaction.py')
SQL_FILES = ('09d_clear_all_tables.sql', '06b_validate_live_inline.sql',
             '06c_validate_cross_table.sql')
TABLES = ('finance_dashboard_daily', 'finance_dashboard_arap_daily',
          'finance_dashboard_aging_daily', 'finance_dashboard_expense_daily',
          'finance_dashboard_coverage')
UUID = '629148b0-9f15-11ee-bf49-2569bf801689'
START = '2026-10-14T14:03:11.123456Z'
STAMP = '2026-10-15 07:58:21.402113'
COLUMNS = {
    'finance_dashboard_daily': ['id', 'company_id', 'date', 'sales', 'cogs', 'opex'],
    'finance_dashboard_arap_daily': ['id', 'company_id', 'date', 'date_maturity', 'partner_id',
                                     'is_intercompany', 'ar_amount', 'ap_amount'],
    'finance_dashboard_aging_daily': ['id', 'company_id', 'date', 'date_maturity',
                                      'ar_amount', 'ap_amount'],
    'finance_dashboard_expense_daily': ['id', 'company_id', 'account_id', 'date', 'amount'],
    'finance_dashboard_coverage': ['id', 'company_id', 'covered_from', 'covered_to', 'dirty_from',
                                   'last_refresh_at', 'last_refresh_ok'],
}
MEASURES_06B = ('ap', 'ap_ic', 'ar', 'ar_ic', 'cash', 'cogs', 'cogs_ic',
                'depreciation', 'oca', 'oca_ic', 'ocl', 'ocl_ic', 'opex',
                'other_income', 'sales', 'sales_ic')
INVARIANTS_06C = ('aging.ap   = arap.ap non-IC', 'aging.ar   = arap.ar non-IC',
                  'arap.ap    = daily.ap_delta', 'arap.ap_ic = daily.ap_ic_delta',
                  'arap.ar    = daily.ar_delta', 'arap.ar_ic = daily.ar_ic_delta',
                  'expense    = opex+cogs+dep')
WRITE_KINDS = {'file:09d_clear_all_tables.sql', 'copy-from'}
FORBIDDEN = re.compile(r'\b(setval|nextval|analyze|vacuum|truncate|insert|update|create|'
                       r'drop|alter|grant|revoke|reindex|cluster|lock\s+table)\b', re.I)
MISSING = object()

with open(DRIVER_PATH) as handle:
    DRIVER_SRC = handle.read()
DRIVER_CODE = compile(DRIVER_SRC, DRIVER_PATH, 'exec')
SQL_TEXT = {}
for _name in SQL_FILES:
    with open(os.path.join(HERE, _name), encoding='utf-8') as handle:
        SQL_TEXT[_name] = handle.read()
PINS = {name: hashlib.sha256(SQL_TEXT[name].encode('utf-8')).hexdigest() for name in SQL_FILES}


def make_data(table, n):
    """COPY text lines as pg_dump writes them, deliberately not sorted."""
    rnd = random.Random(table)
    lines = []
    for i in range(n, 0, -1):
        cells = [str(i), str(1 + i % 2)] + [str(rnd.randint(-99999, 99999)) + '.' + str(rnd.randint(10, 99))
                                           for _ in COLUMNS[table][2:]]
        if table == 'finance_dashboard_coverage':
            cells[5] = STAMP if i == 1 else '2026-10-15 07:58:20.1'
            cells[4] = '\\N'
        lines.append('\t'.join(cells))
    return ('\n'.join(lines) + '\n').encode('utf-8')


DATA = {t: make_data(t, n) for t, n in zip(TABLES, (12, 30, 17, 9, 2))}


def sort_sha256(blob):
    """The reference: the bytes through `LC_ALL=C sort`, then SHA-256 - what 12d does."""
    sorted_out = subprocess.run(['sort'], input=blob, stdout=subprocess.PIPE, check=True,
                                env=dict(os.environ, LC_ALL='C')).stdout
    return len(sorted_out.splitlines()), hashlib.sha256(sorted_out).hexdigest()


REFERENCE = {t: sort_sha256(DATA[t]) for t in TABLES}


class FakeDbError(Exception):
    def __init__(self, message, pgcode=None):
        super().__init__(message)
        self.pgcode = pgcode


class Scenario:
    """What the stand-in database does in one run."""

    def __init__(self, **kw):
        self.identity = kw.pop('identity', ('repeatable read', 'gftuae', True, UUID, START,
                                            'ISO, MDY', 'postgres', '3', 'UTF8', '0', '0',
                                            'on', 'off'))
        self.columns = kw.pop('columns', COLUMNS)
        self.fail_06b = kw.pop('fail_06b', None)
        self.fail_06c = kw.pop('fail_06c', None)
        self.short_06c = kw.pop('short_06c', False)
        self.stamp = kw.pop('stamp', STAMP)
        self.clear_broken = kw.pop('clear_broken', False)
        self.copy_error = kw.pop('copy_error', None)
        self.mutate = kw.pop('mutate', None)          # the database returns this table changed
        self.lock_error = kw.pop('lock_error', False)
        self.sequences_move = kw.pop('sequences_move', False)
        self.sequence_missing = kw.pop('sequence_missing', False)
        self.behind = kw.pop('behind', False)
        self.commit_error = kw.pop('commit_error', False)
        self.rollback_error = kw.pop('rollback_error', False)
        self.connect_error = kw.pop('connect_error', False)
        self.numeric = kw.pop('numeric', Decimal)
        if kw:
            raise TypeError('unknown scenario keys: ' + ', '.join(kw))


def classify(query):
    for marker in ('identity', 'columns', 'rows', 'sequences', 'max-id', 'stamp'):
        if '/* fd5:' + marker + ' */' in query:
            return marker
    if '/* fd5:lock */' in query:
        return 'lock-set' if 'SET LOCAL' in query else 'lock-get'
    for name, text in SQL_TEXT.items():
        if query == text:
            return 'file:' + name
    return 'UNKNOWN'


COPY_FROM = re.compile(r'COPY public\."([a-z_]+)" \(((?:"[a-z_0-9]+"(?:, )?)+)\) FROM STDIN$')
COPY_TO = re.compile(r'COPY public\."([a-z_]+)" TO STDOUT$')


class FakeCursor:
    def __init__(self, sc, db, conn):
        self.sc, self.db, self.conn = sc, db, conn
        self.result = []
        self.rowcount = -1

    def execute(self, query, params=None):
        if params is not None:
            raise AssertionError('the driver passed parameters to execute()')
        kind = classify(query)
        self.conn.log.append((kind, query))
        sc, db = self.sc, self.db
        self.result = []
        if kind == 'UNKNOWN':
            raise AssertionError('unexpected statement: ' + query[:120])
        if kind == 'identity':
            self.result = [sc.identity]
        elif kind == 'columns':
            self.result = [(t, c) for t in sorted(sc.columns) for c in sc.columns[t]]
        elif kind == 'rows':
            self.result = [tuple(len(db[t]) for t in TABLES)]
        elif kind == 'sequences':
            self.conn.sequence_reads += 1
            moved = sc.sequences_move and self.conn.sequence_reads > 1
            self.result = [(t, None if (sc.sequence_missing and i == 2) else 'public.' + t + '_id_seq',
                            1000 + i + (5 if moved else 0)) for i, t in enumerate(TABLES)]
        elif kind == 'max-id':
            self.result = [tuple((2000 if sc.behind else 900) + i for i in range(5))]
        elif kind == 'lock-set':
            if not re.search(r"SET LOCAL lock_timeout = '[1-9][0-9]*(ms|s|min)'$", query):
                raise AssertionError('unexpected lock statement: ' + query)
            if sc.lock_error:
                raise FakeDbError('canceling statement due to lock timeout', '55P03')
        elif kind == 'lock-get':
            self.result = [('1min',)]
        elif kind == 'stamp':
            self.result = [(sc.stamp,)]
        elif kind == 'file:09d_clear_all_tables.sql':
            for t in TABLES:
                db[t] = [] if not (sc.clear_broken and t == TABLES[1]) else [b'left behind']
        elif kind == 'file:06b_validate_live_inline.sql':
            self.result = [(m, sc.numeric('100.00'), sc.numeric('100.00') if m != sc.fail_06b
                            else sc.numeric('101.00'), sc.numeric('0.00') if m != sc.fail_06b
                            else sc.numeric('1.00'), 'FAIL' if m == sc.fail_06b else 'PASS')
                           for m in MEASURES_06B]
        elif kind == 'file:06c_validate_cross_table.sql':
            rows = [(c, sc.numeric('5.00'), sc.numeric('5.00'), sc.numeric('0.00'),
                     'FAIL' if c == sc.fail_06c else 'PASS') for c in INVARIANTS_06C]
            self.result = rows[:6] if sc.short_06c else rows

    def fetchone(self):
        return self.result[0]

    def fetchall(self):
        return list(self.result)

    def copy_expert(self, sql, handle):
        match_from, match_to = COPY_FROM.match(sql), COPY_TO.match(sql)
        if match_from:
            table = match_from.group(1)
            self.conn.log.append(('copy-from', sql))
            if table not in TABLES:
                raise AssertionError('COPY into a table outside the five: ' + table)
            columns = [c.strip('"') for c in match_from.group(2).split(', ')]
            if columns != COLUMNS[table]:
                raise AssertionError('COPY column list differs from the record: ' + sql)
            if self.sc.copy_error == table:
                raise FakeDbError('invalid input syntax for type numeric', '22P02')
            blob = handle.read()
            lines = blob.split(b'\n')[:-1]
            self.db[table].extend(lines)
            self.rowcount = len(lines)
        elif match_to:
            table = match_to.group(1)
            self.conn.log.append(('copy-to', sql))
            lines = list(reversed(self.db[table]))          # any order: the driver sorts
            if self.sc.mutate == table and lines:
                lines[0] = lines[0] + b'0'
            handle.write(b''.join(line + b'\n' for line in lines))
            self.rowcount = len(lines)
        else:
            raise AssertionError('unexpected COPY statement: ' + sql)


class FakeConn:
    def __init__(self, sc):
        self.sc = sc
        self.log = []
        self.commits = 0
        self.rollbacks = 0
        self.rollback_after = []        # index in log at each rollback
        self.sequence_reads = 0
        self.db = {t: [b'old row %d' % i for i in range(3)] for t in TABLES}
        self.cur = FakeCursor(sc, self.db, self)

    def cursor(self):
        return self.cur

    def commit(self):
        self.commits += 1
        if self.sc.commit_error:
            raise FakeDbError('server closed the connection unexpectedly')

    def rollback(self):
        self.rollbacks += 1
        self.rollback_after.append(len(self.log))
        if self.sc.rollback_error:
            raise FakeDbError('connection already closed')


class Run:
    def __init__(self, lines, conn, opened, connected):
        self.lines = lines
        self.conn = conn
        self.opened = opened            # the driver asked for a connection
        self.connected = connected      # ... and got one
        fd5 = [line for line in lines if line.startswith('FD5|')]
        self.fd5 = fd5
        outcomes = [line for line in fd5 if line.startswith('FD5|outcome|')]
        self.outcomes = outcomes
        self.outcome = outcomes[-1] if outcomes else ''
        self.kind = self.outcome.split('|')[2] if outcomes else ''


def write_inputs(folder, plan_edit=None, data_edit=None):
    plan = {'tables': {t: {'columns': list(COLUMNS[t]), 'rows': REFERENCE[t][0],
                           'copy_sha256': REFERENCE[t][1]} for t in TABLES},
            'layer_refresh_time': STAMP,
            'archive_sha256': '0' * 64, 'record_sha256': '1' * 64}
    if plan_edit:
        plan_edit(plan)
    raw = json.dumps(plan, indent=1).encode('utf-8')
    with open(os.path.join(folder, 'plan.json'), 'wb') as handle:
        handle.write(raw)
    for t in TABLES:
        blob = DATA[t] if not (data_edit and t in data_edit) else data_edit[t]
        with open(os.path.join(folder, t + '.copy'), 'wb') as handle:
            handle.write(blob)
    return hashlib.sha256(raw).hexdigest()


def run(mode='rollback-only', env_edit=None, plan_edit=None, data_edit=None, plan_sha=None, **sc_kw):
    sc = Scenario(**sc_kw)
    folder = tempfile.mkdtemp(prefix='fd5test_')
    try:
        sha = write_inputs(folder, plan_edit, data_edit)
        env = {'FD5_MODE': mode, 'FD5_SOCKET_DIR': '/var/run/postgresql', 'FD5_PORT': '5432',
               'FD5_DATABASE': 'gftuae', 'FD5_EXPECTED_UUID': UUID,
               'FD5_PRE_POSTMASTER_START': START, 'FD5_LOCK_TIMEOUT': '60s', 'FD5_DIR': HERE,
               'FD5_PINS': ';'.join(k + '=' + v for k, v in PINS.items()),
               'FD5_DATA_DIR': folder, 'FD5_PLAN_SHA256': plan_sha or sha}
        if env_edit:
            env_edit(env)
        saved = {k: os.environ.get(k) for k in env}
        for k in list(os.environ):
            if k.startswith('FD5_'):
                saved.setdefault(k, os.environ[k])
                del os.environ[k]
        for k, v in env.items():
            if v is not MISSING:
                os.environ[k] = v
        conn = FakeConn(sc)
        opened = []

        def opener(cfg):
            opened.append(cfg)
            if sc.connect_error:
                raise FakeDbError('could not connect to server: No such file or directory')
            return conn

        buffer = io.StringIO()
        namespace = {'__name__': 'fd5_test', '__file__': DRIVER_PATH}
        with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(io.StringIO()):
            exec(DRIVER_CODE, namespace)
            namespace['main'](opener)
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        return Run(buffer.getvalue().splitlines(), conn, bool(opened),
                   bool(opened) and not sc.connect_error)
    finally:
        shutil.rmtree(folder)


# ---- checks ---------------------------------------------------------------------------------
results = []


def check(name, condition, detail=''):
    results.append((name, bool(condition), detail))


def invariants(name, r, expect_commit):
    """The properties every run must have."""
    problems = []
    if len(r.outcomes) != 1:
        problems.append('%d outcome lines' % len(r.outcomes))
    elif r.fd5[-1] != r.outcome:
        problems.append('the outcome is not the last FD5 line')
    if r.conn.commits != (1 if expect_commit else 0):
        problems.append('commit() called %d time(s)' % r.conn.commits)
    kinds = [kind for kind, _ in r.conn.log]
    writes = [i for i, kind in enumerate(kinds) if kind in WRITE_KINDS]
    if writes and kinds[writes[0]] != 'file:09d_clear_all_tables.sql':
        problems.append('the first write is not the clear: ' + kinds[writes[0]])
    if r.kind == 'ROLLED_BACK' and 'refused' in r.outcome and writes:
        problems.append('a refused run wrote')
    for kind, query in r.conn.log:
        if kind in ('copy-from', 'copy-to'):
            continue
        if kind.startswith('file:'):
            continue        # the pinned files, executed exactly as approved
        if FORBIDDEN.search(query):
            problems.append('forbidden statement: ' + query[:80])
    if r.connected and r.conn.commits == 0:
        last_statement = len(r.conn.log)
        if not r.conn.rollback_after or r.conn.rollback_after[-1] != last_statement:
            problems.append('no rollback after the last statement')
    check(name + ' - invariants', not problems, '; '.join(problems))


# 1. no test can commit: modes x outcomes ------------------------------------------------------
MODE_VALUES = ['live', 'rollback-only', 'LIVE', ' live', 'live ', 'rollback', 'test', '',
               MISSING, 'live;rollback-only']
OUTCOMES = {
    'every step passes': {},
    'a 06b check fails': {'fail_06b': 'sales'},
    'a 06c check fails': {'fail_06c': 'expense    = opex+cogs+dep'},
    'restored rows differ': {'mutate': 'finance_dashboard_arap_daily'},
    'refresh time differs': {'stamp': '2026-10-15 08:00:00.000000'},
    'sequences moved': {'sequences_move': True},
    'identity differs': {'identity': ('repeatable read', 'gftuae', True, 'x', START,
                                      'ISO, MDY', 'postgres', '3', 'UTF8', '0', '0', 'on', 'off')},
    'columns differ': {'columns': dict(COLUMNS, finance_dashboard_aging_daily=['id', 'company_id'])},
    'COPY fails': {'copy_error': 'finance_dashboard_expense_daily'},
    'the clear leaves rows': {'clear_broken': True},
    'lock timeout': {'lock_error': True},
    'commit raises': {'commit_error': True},
    'cannot connect': {'connect_error': True},
}
grid_fail = []
for mode, (label, kw) in itertools.product(MODE_VALUES, OUTCOMES.items()):
    r = run(mode=mode, **kw)
    valid = mode in ('live', 'rollback-only')
    all_pass = label in ('every step passes', 'commit raises')
    expect_commit = mode == 'live' and all_pass
    invariants('grid %r / %s' % ('MISSING' if mode is MISSING else mode, label), r, expect_commit)
    if not valid and r.opened:
        grid_fail.append('%r opened a connection' % mode)
    if r.conn.commits and not expect_commit:
        grid_fail.append('%r / %s committed' % (mode, label))
check('grid: %d runs, commit only for live + every check passed' % (len(MODE_VALUES) * len(OUTCOMES)),
      not grid_fail, '; '.join(grid_fail))

# 2. named cases ---------------------------------------------------------------------------------


def named(name, want_kind, want_text=None, expect_commit=False, **kw):
    r = run(**kw)
    invariants(name, r, expect_commit)
    ok = r.outcome.startswith('FD5|outcome|' + want_kind) and (want_text is None or want_text in r.outcome)
    check(name, ok, r.outcome)
    return r


r = named('rollback-only: everything passes', 'ROLLED_BACK|test')
check('rollback-only: 23 checks reported', sum(1 for line in r.fd5 if line.startswith('FD5|check|')) == 23)
check('rollback-only: five tables compared MATCH',
      sum(1 for line in r.fd5 if line.startswith('FD5|compare|') and line.endswith('|MATCH')) == 5)
check('rollback-only: sequences unchanged reported', 'FD5|sequences|unchanged' in r.fd5)
check('rollback-only: loaded rows = record',
      [line.split('|')[3] for line in r.fd5 if line.startswith('FD5|loaded|')]
      == [str(REFERENCE[t][0]) for t in TABLES])
r = named('live: everything passes -> COMMITTED', 'COMMITTED', expect_commit=True, mode='live')
check('live: commit ATTEMPTED then DONE',
      'FD5|commit|ATTEMPTED' in r.fd5 and 'FD5|commit|DONE' in r.fd5
      and r.fd5.index('FD5|commit|ATTEMPTED') < r.fd5.index('FD5|commit|DONE'))
r = named('live: a sequence behind the restored ids is reported, not set', 'COMMITTED',
          expect_commit=True, mode='live', behind=True)
check('live: BEHIND reported for all five', sum(1 for line in r.fd5 if line.endswith('|BEHIND')) == 5)
named('live: commit raises -> UNKNOWN', 'UNKNOWN', 'server closed', expect_commit=True,
      mode='live', commit_error=True)
named('live: commit raises, rollback raises too -> UNKNOWN', 'UNKNOWN', expect_commit=True,
      mode='live', commit_error=True, rollback_error=True)
named('float amounts (any driver) print with two decimals', 'ROLLED_BACK|test', numeric=float)
named('mode missing -> refused', 'ROLLED_BACK|refused', 'FD5_MODE', mode=MISSING)
named('mode misspelt -> refused', 'ROLLED_BACK|refused', 'unknown FD5_MODE', mode='Live')
named('socket given as a host name -> refused', 'ROLLED_BACK|refused', 'socket folder',
      env_edit=lambda e: e.update(FD5_SOCKET_DIR='10.0.0.5'))
named('socket given as localhost -> refused', 'ROLLED_BACK|refused', 'socket folder',
      env_edit=lambda e: e.update(FD5_SOCKET_DIR='localhost'))
named('port not a number -> refused', 'ROLLED_BACK|refused', 'FD5_PORT',
      env_edit=lambda e: e.update(FD5_PORT='5432;x'))
named('lock timeout malformed -> refused', 'ROLLED_BACK|refused', 'LOCK_TIMEOUT',
      env_edit=lambda e: e.update(FD5_LOCK_TIMEOUT='60s; DROP'))
named('plan hash malformed -> refused', 'ROLLED_BACK|refused', 'PLAN_SHA256',
      env_edit=lambda e: e.update(FD5_PLAN_SHA256='abc'))
named('pins malformed -> refused', 'ROLLED_BACK|refused', 'FD5_PINS',
      env_edit=lambda e: e.update(FD5_PINS='09d_clear_all_tables.sql=zz'))
named('a pin missing -> refused', 'ROLLED_BACK|refused', 'no approved hash',
      env_edit=lambda e: e.update(FD5_PINS=';'.join(k + '=' + v for k, v in PINS.items()
                                                    if k != '06b_validate_live_inline.sql')))
named('a SQL file differs from its pin -> refused', 'ROLLED_BACK|refused', 'approved hash',
      env_edit=lambda e: e.update(FD5_PINS=e['FD5_PINS'].replace(PINS['06c_validate_cross_table.sql'],
                                                                 'a' * 64)))
named('plan differs from the pre-check hash -> refused', 'ROLLED_BACK|refused', 'restore plan',
      plan_sha='b' * 64)
named('plan names four tables -> refused', 'ROLLED_BACK|refused', 'not readable',
      plan_edit=lambda p: p['tables'].pop('finance_dashboard_coverage'))
named('plan column name not an identifier -> refused', 'ROLLED_BACK|refused', 'identifier',
      plan_edit=lambda p: p['tables']['finance_dashboard_daily']['columns'].append('x"; DROP'))
named('data file one row short -> refused', 'ROLLED_BACK|refused', 'data file',
      data_edit={'finance_dashboard_arap_daily': b'\n'.join(DATA['finance_dashboard_arap_daily']
                                                            .split(b'\n')[1:])})
named('data file one byte changed -> refused', 'ROLLED_BACK|refused', 'data file',
      data_edit={'finance_dashboard_coverage': DATA['finance_dashboard_coverage'].replace(b'1', b'7', 1)})
named('live columns differ from the archive -> refused', 'ROLLED_BACK|refused', 'schema changed',
      columns=dict(COLUMNS, finance_dashboard_coverage=COLUMNS['finance_dashboard_coverage'][:-1]))
named('a column added to a live table -> refused', 'ROLLED_BACK|refused', 'schema changed',
      columns=dict(COLUMNS, finance_dashboard_daily=COLUMNS['finance_dashboard_daily'] + ['x']))
for index, label, value in ((0, 'isolation read committed', 'read committed'),
                            (1, 'another database', 'gftuae2'),
                            (2, 'a TCP connection', False),
                            (3, 'another uuid', 'deadbeef'),
                            (4, 'the cluster restarted', '2026-10-15T00:00:00.000000Z'),
                            (5, 'DateStyle SQL', 'SQL, DMY'),
                            (8, 'client_encoding LATIN1', 'LATIN1'),
                            (12, 'read-only session', 'on')):
    ident = list(Scenario().identity)
    ident[index] = value
    named('identity: ' + label + ' -> refused', 'ROLLED_BACK|refused', identity=tuple(ident))
named('a sequence cannot be found -> error', 'ROLLED_BACK|error', 'sequences', sequence_missing=True)
named('lock timeout before the clear -> error, nothing written', 'ROLLED_BACK|error', '55P03',
      lock_error=True)
named('the clear leaves rows -> error', 'ROLLED_BACK|error', 'left rows behind', clear_broken=True)
named('COPY fails on one table -> error', 'ROLLED_BACK|error', '22P02',
      copy_error='finance_dashboard_expense_daily')
named('restored rows differ from the record -> gate', 'ROLLED_BACK|gate', 'finance_dashboard_daily',
      mutate='finance_dashboard_daily')
named('refresh time differs -> gate', 'ROLLED_BACK|gate', 'refresh time', stamp='')
named('06b sales fails -> gate', 'ROLLED_BACK|gate', '06b sales 1.00', fail_06b='sales')
named('06c invariant fails -> gate', 'ROLLED_BACK|gate', '06c expense', fail_06c='expense    = opex+cogs+dep')
named('06c returns 6 rows -> gate', 'ROLLED_BACK|gate', 'expected 7', short_06c=True)
named('sequences moved during the transaction -> gate', 'ROLLED_BACK|gate', 'sequences moved',
      sequences_move=True)
named('gate fails and rollback raises -> still gate', 'ROLLED_BACK|gate', fail_06b='ar',
      rollback_error=True)
named('live + gate fails -> rolled back, not committed', 'ROLLED_BACK|gate', mode='live', fail_06b='cash')
named('cannot connect -> error, nothing written', 'ROLLED_BACK|error', 'could not connect',
      connect_error=True)

# 3. the source itself -----------------------------------------------------------------------------
check('source: exactly one commit() call', len(re.findall(r'\.commit\(\)', DRIVER_SRC)) == 1)
check('source: every open() is read-only binary',
      all(call.endswith("'rb')") for call in re.findall(r"open\([^)]*\)", DRIVER_SRC)))
CODE_NAMES = [tok.string for tok in tokenize.generate_tokens(io.StringIO(DRIVER_SRC).readline)
              if tok.type == tokenize.NAME]
check('source: no exit() or quit() in the code (comments aside)',
      not {'exit', 'quit', '_exit'} & set(CODE_NAMES))
check('source: no percent sign', '%' not in DRIVER_SRC)

# 4. content() = LC_ALL=C sort | sha256sum ---------------------------------------------------------
ns = {'__name__': 'fd5_test'}
exec(DRIVER_CODE, ns)
rnd = random.Random(7)
sample = b''.join(('%d\t%s\t\\N\tt\t%s\n' % (rnd.randint(1, 10 ** 6), rnd.choice(['a', 'B', 'é', '_', 'Z']),
                                             rnd.random())).encode('utf-8') for _ in range(5000))
for label, blob in (('5000 mixed rows', sample), ('empty table', b''), ('one row', b'1\t2\n')):
    check('content() = sort|sha256sum: ' + label, ns['content'](blob) == sort_sha256(blob))
check('amount(): Decimal and float', ns['amount'](Decimal('1')) == '1.00' and ns['amount'](1.0) == '1.00'
      and ns['amount'](None) == '')

# ---- report ----------------------------------------------------------------------------------------
fails = [item for item in results if not item[1]]
for name, ok, detail in results:
    if not ok or os.environ.get('VERBOSE'):
        print('%s  %s%s' % ('PASS' if ok else 'FAIL', name, ('  -- ' + detail) if detail and not ok else ''))
print('%d checks: %d PASS, %d FAIL' % (len(results), len(results) - len(fails), len(fails)))
sys.exit(1 if fails else 0)
