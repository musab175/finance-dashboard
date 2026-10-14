# -*- coding: utf-8 -*-
# =============================================================================
# 09b_restore_transaction.py - Finance Dashboard bootstrap, SECTION 5: the
# restore transaction. 2026-10-14.
#
# RUN ONLY BY 09_restore_reporting.sh. It feeds this file to `python3 -P -` on
# stdin, AS THE postgres USER, from the folder /, and passes every instruction
# in FD5_* environment variables. Run any other way, this file refuses before
# it touches anything.
#
# ONE TRANSACTION, REPEATABLE READ, on a plain psycopg2 connection through the
# local Unix socket - no Odoo. The load and all 23 checks read one snapshot.
#   1. identity      REPEATABLE READ; the connection came through the socket
#                    (inet_server_addr() IS NULL); the database, its uuid and
#                    the cluster start time equal the pre-check's; DateStyle
#                    ISO, IntervalStyle postgres, extra_float_digits 3 and
#                    client_encoding UTF8 - the settings pg_dump wrote the
#                    archive's rows with, so a row prints the same both ways
#   2. files         the clear, 06b and 06c, and the plan, hashed against their
#                    pins: the SQL executed is the very bytes that were hashed.
#                    Each data file's rows and sorted-row SHA-256 equal the
#                    record's. Each table's columns, in order, equal the
#                    record's. All of this before anything is written
#   3. lock_timeout  SET LOCAL, so a conflicting lock fails the run
#   4. sequences     the five id sequences' last_value, before
#   5. clear         09d_clear_all_tables.sql; then all five must be empty
#   6. load          COPY public.<table> (<checked columns>) FROM STDIN, each
#                    table from its data file, with the rows' own ids
#   7. compare       per table: COPY TO STDOUT, sorted byte-wise, row count and
#                    SHA-256 equal the record's - the tables now hold exactly
#                    the archive's rows; the refresh time equals the record's
#   8. gate          06b (16 checks) and 06c (7 checks): every row must PASS
#   9. sequences     unchanged since step 4: rows loaded with their own ids
#                    draw no number from a sequence
#  10. commit        live mode only, and only after 1-9 passed. Otherwise ROLLBACK.
# Steps 1-4 write nothing. The first write is step 5.
#
# A TEST NEVER COMMITS. commit_allowed is true only for FD5_MODE=live. finish()
# is the only place that calls commit, and it checks commit_allowed first. A
# missing, empty or misspelt value is refused before a connection is opened.
#
# NEVER: setval, ANALYZE, VACUUM, TRUNCATE, any DDL, or any statement taken from
# the archive. Only the archive's data rows are loaded, into a column list
# checked against the live table. A sequence below the restored ids is
# reported here and checked again after the commit by 09_restore_reporting.sh
# (exit 54): this file never sets one.
#
# OUTPUT: one line per fact, "FD5|<key>|<value>|...", flushed at once; values
# never contain "|". 09_restore_reporting.sh decides the result from these
# lines, not from python's exit status. The last line is always the outcome:
#   FD5|outcome|COMMITTED              commit() returned: PostgreSQL confirmed it
#   FD5|outcome|UNKNOWN|<error>        commit() raised: the outcome must be
#                                      checked through a fresh connection
#   FD5|outcome|ROLLED_BACK|refused|.. a precondition failed; nothing written
#   FD5|outcome|ROLLED_BACK|gate|..    a comparison or check failed
#   FD5|outcome|ROLLED_BACK|test|..    a test passed every check
#   FD5|outcome|ROLLED_BACK|error|..   an exception; the transaction is discarded
# This file never calls sys.exit and never writes a file.
#
# No statement is given parameters, and none contains a percent sign, so
# psycopg2 interpolates nothing.
# =============================================================================
import hashlib
import io
import json
import os
import re
import sys
import time
import traceback
from decimal import Decimal, InvalidOperation

MODES = ('live', 'rollback-only')
REQUIRED = ('FD5_MODE', 'FD5_SOCKET_DIR', 'FD5_PORT', 'FD5_DATABASE',
            'FD5_EXPECTED_UUID', 'FD5_PRE_POSTMASTER_START', 'FD5_LOCK_TIMEOUT',
            'FD5_DIR', 'FD5_PINS', 'FD5_DATA_DIR', 'FD5_PLAN_SHA256')
TABLES = ('finance_dashboard_daily', 'finance_dashboard_arap_daily',
          'finance_dashboard_aging_daily', 'finance_dashboard_expense_daily',
          'finance_dashboard_coverage')
CLEAR = '09d_clear_all_tables.sql'
GATE = (('06b', '06b_validate_live_inline.sql', 16),
        ('06c', '06c_validate_cross_table.sql', 7))
PLAN = 'plan.json'
NAME = re.compile(r'[a-z_][a-z0-9_]*')
# The settings pg_dump uses for its COPY output, read back in step 1.
SESSION_OPTIONS = '-c DateStyle=ISO -c IntervalStyle=postgres -c extra_float_digits=3'

IDENTITY_SQL = """/* fd5:identity */
SELECT current_setting('transaction_isolation'),
       current_database(),
       inet_server_addr() IS NULL,
       (SELECT value FROM public.ir_config_parameter WHERE key = 'database.uuid'),
       to_char(pg_postmaster_start_time() AT TIME ZONE 'UTC',
               'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
       current_setting('DateStyle'),
       current_setting('IntervalStyle'),
       current_setting('extra_float_digits'),
       current_setting('client_encoding'),
       current_setting('statement_timeout'),
       current_setting('idle_in_transaction_session_timeout'),
       current_setting('synchronous_commit'),
       current_setting('default_transaction_read_only')"""

COLUMNS_SQL = """/* fd5:columns */
SELECT table_name, column_name
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND table_name IN ('finance_dashboard_daily', 'finance_dashboard_arap_daily',
                      'finance_dashboard_aging_daily', 'finance_dashboard_expense_daily',
                      'finance_dashboard_coverage')
 ORDER BY table_name, ordinal_position"""

ROWS_SQL = """/* fd5:rows */
SELECT (SELECT count(*) FROM public.finance_dashboard_daily),
       (SELECT count(*) FROM public.finance_dashboard_arap_daily),
       (SELECT count(*) FROM public.finance_dashboard_aging_daily),
       (SELECT count(*) FROM public.finance_dashboard_expense_daily),
       (SELECT count(*) FROM public.finance_dashboard_coverage)"""

# last_value is NULL until a sequence is first used; max(id) is the restored rows'.
SEQUENCES_SQL = """/* fd5:sequences */
SELECT t.name, pg_get_serial_sequence('public.' || t.name, 'id'), s.last_value
  FROM unnest(ARRAY['finance_dashboard_daily', 'finance_dashboard_arap_daily',
                    'finance_dashboard_aging_daily', 'finance_dashboard_expense_daily',
                    'finance_dashboard_coverage']) WITH ORDINALITY AS t(name, n)
  LEFT JOIN pg_sequences s
         ON quote_ident(s.schemaname) || '.' || quote_ident(s.sequencename)
            = pg_get_serial_sequence('public.' || t.name, 'id')
 ORDER BY t.n"""

MAX_ID_SQL = """/* fd5:max-id */
SELECT (SELECT max(id) FROM public.finance_dashboard_daily),
       (SELECT max(id) FROM public.finance_dashboard_arap_daily),
       (SELECT max(id) FROM public.finance_dashboard_aging_daily),
       (SELECT max(id) FROM public.finance_dashboard_expense_daily),
       (SELECT max(id) FROM public.finance_dashboard_coverage)"""

# The SAME text 12_refresh.sh, 12a and 09a use.
STAMP_SQL = "SELECT COALESCE(to_char(max(last_refresh_at), 'YYYY-MM-DD HH24:MI:SS.US'), '') FROM finance_dashboard_coverage"


class Refused(Exception):
    """A precondition failed. Nothing has been written."""


class GateFailed(Exception):
    """A comparison or a check failed."""


def out(*fields):
    print('|'.join(['FD5'] + [_clean(field) for field in fields]), flush=True)


def _clean(value):
    text = '' if value is None else str(value)
    return text.replace('|', '/').replace('\r', ' ').replace('\n', ' ')


def amount(value):
    """A gate amount as text with two decimals (Decimal from psycopg2, or float).

    Display only: PASS or FAIL is decided inside the SQL and never depends on this.
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


def content(data):
    """Rows and SHA-256 of COPY text, sorted byte-wise - what 12d and 09a record."""
    lines = data.split(b'\n')
    if lines and lines[-1] == b'':
        lines.pop()
    lines.sort()
    joined = b''.join(line + b'\n' for line in lines)
    return len(lines), hashlib.sha256(joined).hexdigest()


def quoted(name):
    if not NAME.fullmatch(name):
        raise Refused('unexpected identifier ' + repr(name))
    return '"' + name + '"'


def read_config():
    values = {key: os.environ.get(key, '') for key in REQUIRED}
    missing = [key for key in REQUIRED if not values[key]]
    if missing:
        raise Refused('missing instruction(s) ' + ', '.join(missing)
                      + ' - run this file only through 09_restore_reporting.sh')
    if values['FD5_MODE'] not in MODES:
        raise Refused('unknown FD5_MODE ' + repr(values['FD5_MODE']))
    if not values['FD5_SOCKET_DIR'].startswith('/'):
        raise Refused('FD5_SOCKET_DIR must be a socket folder (an absolute path),'
                      ' never a host name or address: ' + repr(values['FD5_SOCKET_DIR']))
    if not re.fullmatch(r'[1-9][0-9]{0,4}', values['FD5_PORT']):
        raise Refused('invalid FD5_PORT ' + repr(values['FD5_PORT']))
    if not re.fullmatch(r'[1-9][0-9]{0,5}(ms|s|min)', values['FD5_LOCK_TIMEOUT']):
        raise Refused('invalid FD5_LOCK_TIMEOUT ' + repr(values['FD5_LOCK_TIMEOUT']))
    if not re.fullmatch(r'[0-9a-f]{64}', values['FD5_PLAN_SHA256']):
        raise Refused('invalid FD5_PLAN_SHA256 ' + repr(values['FD5_PLAN_SHA256']))
    pins = {}
    for item in values['FD5_PINS'].split(';'):
        name, sep, digest = item.partition('=')
        if not sep or not name or name in pins \
                or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise Refused('malformed FD5_PINS entry ' + repr(item))
        pins[name] = digest
    return {
        'mode': values['FD5_MODE'],
        'socket_dir': values['FD5_SOCKET_DIR'],
        'port': int(values['FD5_PORT']),
        'db': values['FD5_DATABASE'],
        'uuid': values['FD5_EXPECTED_UUID'],
        'postmaster_start': values['FD5_PRE_POSTMASTER_START'],
        'lock_timeout': values['FD5_LOCK_TIMEOUT'],
        'dir': values['FD5_DIR'],
        'pins': pins,
        'data_dir': values['FD5_DATA_DIR'],
        'plan_sha256': values['FD5_PLAN_SHA256'],
    }


def connect(cfg):
    """The real connection: the local socket only, settings fixed at start-up."""
    import psycopg2
    out('driver', 'psycopg2=' + psycopg2.__version__.split()[0])
    conn = psycopg2.connect(host=cfg['socket_dir'], port=cfg['port'], dbname=cfg['db'],
                            application_name='fd5_restore', client_encoding='UTF8',
                            options=SESSION_OPTIONS, connect_timeout=10)
    conn.set_session(isolation_level='REPEATABLE READ', autocommit=False)
    return conn


def _read(path, what):
    try:
        with open(path, 'rb') as handle:
            return handle.read()
    except OSError as exc:
        raise Refused(what + ': cannot read ' + path + ' (' + describe(exc) + ')')


def check_identity(cur, cfg):
    cur.execute(IDENTITY_SQL)
    isolation, database, socket, uuid, started, datestyle, intervalstyle, \
        float_digits, encoding, statement_timeout, idle_timeout, \
        synchronous_commit, read_only = cur.fetchone()
    out('identity', isolation, database, 'socket=' + str(socket), uuid, started)
    out('session', 'DateStyle=' + str(datestyle), 'IntervalStyle=' + str(intervalstyle),
        'extra_float_digits=' + str(float_digits), 'client_encoding=' + str(encoding),
        'statement_timeout=' + str(statement_timeout),
        'idle_in_transaction_session_timeout=' + str(idle_timeout),
        'synchronous_commit=' + str(synchronous_commit))
    problems = []
    if isolation != 'repeatable read':
        problems.append('isolation is ' + repr(isolation)
                        + ', not REPEATABLE READ - one snapshot is not guaranteed')
    if socket is not True:
        problems.append('the connection did not come through the local Unix socket')
    if database != cfg['db']:
        problems.append('database is ' + repr(database) + ', expected ' + cfg['db'])
    if uuid != cfg['uuid']:
        problems.append('database.uuid is ' + repr(uuid) + ', expected ' + cfg['uuid'])
    if started != cfg['postmaster_start']:
        problems.append('cluster start time ' + str(started) + ' differs from the'
                        ' pre-check (' + cfg['postmaster_start'] + ') - the server'
                        ' restarted, or this is another cluster')
    if not str(datestyle).startswith('ISO') or intervalstyle != 'postgres' \
            or str(float_digits) != '3' or encoding != 'UTF8':
        problems.append('session output settings differ from pg_dump\'s (DateStyle '
                        + str(datestyle) + ', IntervalStyle ' + str(intervalstyle)
                        + ', extra_float_digits ' + str(float_digits)
                        + ', client_encoding ' + str(encoding)
                        + ') - rows would not print as the archive holds them')
    if read_only != 'off':
        problems.append('default_transaction_read_only is ' + repr(read_only))
    if problems:
        raise Refused('; '.join(problems))


def _verify(cfg, key, path):
    pin = cfg['pins'].get(key)
    if pin is None:
        raise Refused('no approved hash supplied for ' + key)
    data = _read(path, key)
    digest = hashlib.sha256(data).hexdigest()
    out('file', key, digest, 'OK' if digest == pin else 'MISMATCH')
    if digest != pin:
        raise Refused(key + ' does not match its approved hash')
    return data


def check_files(cur, cfg):
    texts = {}
    for name in (CLEAR,) + tuple(item[1] for item in GATE):
        texts[name] = _verify(cfg, name, os.path.join(cfg['dir'], name)).decode('utf-8')
    raw = _read(os.path.join(cfg['data_dir'], PLAN), 'the restore plan')
    digest = hashlib.sha256(raw).hexdigest()
    out('file', PLAN, digest, 'OK' if digest == cfg['plan_sha256'] else 'MISMATCH')
    if digest != cfg['plan_sha256']:
        raise Refused('the restore plan does not match the hash the pre-check computed')
    try:
        plan = json.loads(raw.decode('utf-8'))
        tables = plan['tables']
        stamp = plan['layer_refresh_time']
        if list(tables) != list(TABLES):
            raise ValueError('tables ' + repr(list(tables)))
        for name in TABLES:
            entry = tables[name]
            if not isinstance(entry['rows'], int) or entry['rows'] < 0 \
                    or not re.fullmatch(r'[0-9a-f]{64}', entry['copy_sha256']) \
                    or not entry['columns']:
                raise ValueError(name)
            for column in entry['columns']:
                quoted(column)
    except (ValueError, KeyError, TypeError) as exc:
        raise Refused('the restore plan is not readable: ' + describe(exc))
    data = {}
    for name in TABLES:
        blob = _read(os.path.join(cfg['data_dir'], name + '.copy'), name + ' data')
        rows, sha = content(blob)
        want = tables[name]
        ok = rows == want['rows'] and sha == want['copy_sha256']
        out('data', name, rows, sha, 'OK' if ok else 'MISMATCH')
        if not ok:
            raise Refused(name + ': the data file holds ' + str(rows) + ' rows ' + sha[:12]
                          + '..., the record says ' + str(want['rows']) + ' rows '
                          + want['copy_sha256'][:12] + '...')
        data[name] = blob
    cur.execute(COLUMNS_SQL)
    live = {}
    for table, column in cur.fetchall():
        live.setdefault(table, []).append(column)
    for name in TABLES:
        if live.get(name, []) != list(tables[name]['columns']):
            raise Refused(name + ': the live columns ' + repr(live.get(name, []))
                          + ' differ from the archive\'s ' + repr(tables[name]['columns'])
                          + ' - the schema changed; a restore is not assumed safe')
    out('columns', 'MATCH', *(str(len(tables[name]['columns'])) for name in TABLES))
    return texts, plan, data


def set_lock_timeout(cur, cfg):
    value = cfg['lock_timeout']        # validated in read_config: digits + unit
    cur.execute("/* fd5:lock */ SET LOCAL lock_timeout = '" + value + "'")
    cur.execute("/* fd5:lock */ SELECT current_setting('lock_timeout')")
    out('lock_timeout', cur.fetchone()[0])


def sequences(cur, label):
    cur.execute(SEQUENCES_SQL)
    rows = cur.fetchall()
    found = {}
    for table, sequence, last_value in rows:
        out('sequence', label, table, sequence, last_value)
        found[table] = (sequence, last_value)
    if list(found) != list(TABLES) or any(seq is None for seq, _ in found.values()):
        raise RuntimeError('the five id sequences could not all be found: ' + repr(found))
    return found


def layer_rows(cur):
    cur.execute(ROWS_SQL)
    return tuple(int(value) for value in cur.fetchone())


def clear(cur, texts):
    out('rows', 'before-clear', *layer_rows(cur))
    cur.execute(texts[CLEAR])
    after = layer_rows(cur)
    out('rows', 'after-clear', *after)
    if after != (0, 0, 0, 0, 0):
        raise RuntimeError('the clear left rows behind: ' + str(after))


def load(cur, plan, data):
    for name in TABLES:
        columns = ', '.join(quoted(column) for column in plan['tables'][name]['columns'])
        cur.copy_expert('COPY public.' + quoted(name) + ' (' + columns + ') FROM STDIN',
                        io.BytesIO(data[name]))
        out('loaded', name, cur.rowcount)


def compare(cur, plan):
    failures = []
    for name in TABLES:
        buffer = io.BytesIO()
        cur.copy_expert('COPY public.' + quoted(name) + ' TO STDOUT', buffer)
        rows, sha = content(buffer.getvalue())
        want = plan['tables'][name]
        ok = rows == want['rows'] and sha == want['copy_sha256']
        out('compare', name, rows, sha, 'MATCH' if ok else 'DIFF')
        if not ok:
            failures.append(name + ' holds ' + str(rows) + ' rows ' + sha[:12] + '...')
    cur.execute('/* fd5:stamp */ ' + STAMP_SQL)
    stamp = cur.fetchone()[0]
    ok = stamp == plan['layer_refresh_time']
    out('stamp', stamp, 'MATCH' if ok else 'DIFF')
    if not ok:
        failures.append('refresh time ' + repr(stamp) + ', the record says '
                        + repr(plan['layer_refresh_time']))
    return failures


def run_gate(cur, texts):
    failures = []
    for label, name, expected in GATE:
        started = time.time()
        cur.execute(texts[name])
        rows = cur.fetchall()
        passed = 0
        for check, left, right, difference, status in rows:
            out('check', label, check, amount(left), amount(right), amount(difference), status)
            if status == 'PASS':
                passed += 1
            else:
                failures.append(label + ' ' + str(check) + ' ' + amount(difference))
        out('gate', label, str(passed) + '/' + str(len(rows)),
            'expected=' + str(expected), '{:.2f}s'.format(time.time() - started))
        if len(rows) != expected:
            failures.append(label + ' returned ' + str(len(rows)) + ' rows, expected '
                            + str(expected))
    return failures


def sequence_report(cur, before):
    """Sequences must not have moved. Below the restored ids: reported, never set."""
    after = sequences(cur, 'after')
    cur.execute(MAX_ID_SQL)
    for name, max_id in zip(TABLES, cur.fetchone()):
        last_value = after[name][1]
        behind = max_id is not None and (last_value is None or int(last_value) < int(max_id))
        out('sequence-vs-ids', name, last_value, max_id, 'BEHIND' if behind else 'OK')
    if after != before:
        return ['the id sequences moved during the transaction: ' + repr(before)
                + ' -> ' + repr(after)]
    out('sequences', 'unchanged')
    return []


def _rollback(conn):
    if conn is None:
        return
    try:
        conn.rollback()
        out('rollback', 'DONE')
    except Exception as exc:     # the connection may be gone: PostgreSQL then
        out('rollback', 'ERROR', describe(exc))   # discards the transaction itself


def _end(started, *fields):
    out('elapsed', '{:.2f}s'.format(time.time() - started))
    out('outcome', *fields)


def finish(conn, commit_allowed, started):
    if commit_allowed is not True:
        _rollback(conn)
        _end(started, 'ROLLED_BACK', 'test', 'every check passed - a test never commits')
        return
    out('commit', 'ATTEMPTED')
    try:
        conn.commit()            # THE ONLY COMMIT IN THIS FILE
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        out('commit', 'ERROR', describe(exc))
        _rollback(conn)
        _end(started, 'UNKNOWN', describe(exc))
        return
    out('commit', 'DONE')
    _end(started, 'COMMITTED')


def main(open_connection):
    started = time.time()
    try:
        cfg = read_config()
    except Refused as exc:
        _end(started, 'ROLLED_BACK', 'refused', exc)
        return
    commit_allowed = cfg['mode'] == 'live'
    out('start', 'mode=' + cfg['mode'],
        'commit_allowed=' + ('yes' if commit_allowed else 'no'),
        'python=' + sys.version.split()[0])
    conn = None
    try:
        conn = open_connection(cfg)
        cur = conn.cursor()
        check_identity(cur, cfg)                                 # step 1
        texts, plan, data = check_files(cur, cfg)                # step 2
        set_lock_timeout(cur, cfg)                               # step 3
        before = sequences(cur, 'before')                        # step 4
        clear(cur, texts)                                        # step 5
        load(cur, plan, data)                                    # step 6
        failures = compare(cur, plan)                            # step 7
        failures += run_gate(cur, texts)                         # step 8
        failures += sequence_report(cur, before)                 # step 9
        out('rows', 'final', *layer_rows(cur))
        if failures:
            raise GateFailed(str(len(failures)) + ' check(s) failed: ' + '; '.join(failures))
    except Refused as exc:
        _rollback(conn)
        _end(started, 'ROLLED_BACK', 'refused', exc)
        return
    except GateFailed as exc:
        _rollback(conn)
        _end(started, 'ROLLED_BACK', 'gate', exc)
        return
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        _rollback(conn)
        _end(started, 'ROLLED_BACK', 'error', describe(exc))
        return
    finish(conn, commit_allowed, started)                        # step 10


if __name__ == '__main__':
    main(connect)
