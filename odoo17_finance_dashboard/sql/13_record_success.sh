#!/usr/bin/env bash
# =============================================================================
# 13_record_success.sh - Finance Dashboard bootstrap, SECTION 6 (runbook step
# 6b): write the TRUSTED SUCCESS RECORD after a successful build. 2026-10-15.
#
# THE RULE: when this script ends, /var/lib/fd-bootstrap/state.json exists only
# if it describes the reporting layer actually in place:
#   - a committed, verified Section 4 refresh (RESULT 0 or 44, COMMITTED yes,
#     a RECORD_FINGERPRINT_JSON line) wrote it, in a run folder of the exact
#     shape 12_refresh.sh creates (odoo 0750, not a symlink; result.txt and
#     driver.out regular files owned by root, not group/other writable),
#   - no later refresh attempted a commit without succeeding,
#   - the ledger fingerprint now equals that build's,
#   - the refresh time of the layer now equals that build's,
#   - the assessment, given the record, says NOTHING TO DO (module installed,
#     five tables, schema clean, rows present, 06c 7/7).
# An existing record is KEPT only when all of that still holds for it.
# Otherwise nothing new is written, and an EXISTING record that no longer
# matches the fingerprint or the refresh time in place is moved aside
# (state.json.invalid-<UTC>), so no stale record can make a backup look
# restorable. A record that still matches is kept.
#
# READ-ONLY FOR THE DATABASE. It writes only /var/lib/fd-bootstrap.
#
# EXIT CODES
#   0   record written and verified (or already current, rewritten the same)
#   61  refused: no successful build to record (none, not committed, or a
#       later refresh attempted a commit without succeeding)
#   62  refused: stale - the fingerprint or the refresh time in place differs
#       from that build's (a replacement, a restart, a ledger change, another build)
#   63  refused: the layer is missing, incomplete or not sound (the assessment
#       is not 0/10, or not NOTHING TO DO with the record)
#   64  the record could not be written, put in place or verified: the new
#       record is not left in place (an old one only if it still matches)
#   2   could not run (arguments, environment, pinned files): nothing changed
#   any other code is an unexpected abort - never a success; the markers then
#   say RECORD_STATE=unknown: inspect /var/lib/fd-bootstrap by hand.
# Markers, last lines: RECORD_STATE=written|kept|invalidated|absent|unknown|
# unchanged, RECORD_SOURCE=<run folder or none>, RECORD_RESULT=<exit code>.
#
# USAGE
#   sudo bash 13_record_success.sh
#   bash 13_record_success.sh --list-pins
#   bash 13_record_success.sh --facts FILE     (test) made-up facts, a scratch
#                                             state folder named in the facts;
#                                             never as root
# The same folder must hold, pinned: 10_assess.sh, 10a_assess_target.sql,
# 10b_assess_facts.sql, 06c_validate_cross_table.sql.
# =============================================================================
set -euo pipefail

STATE_DIR=/var/lib/fd-bootstrap
RUN_GLOB_PREFIX=/tmp/fd_section4_refresh_
RUN_OWNER=odoo        # 12_refresh.sh: mkdir -m 0750, chown odoo:odoo
RUN_FILE_UID=0        # result.txt and driver.out are written by 12_refresh.sh as root
DATABASE=gftuae
SOCKET_DIR=/var/run/postgresql
SOCKET_PORT=5432
STAMP_SQL="SELECT COALESCE(to_char(max(last_refresh_at), 'YYYY-MM-DD HH24:MI:SS.US'), '') FROM finance_dashboard_coverage"
RE_STAMP='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}$'
PIN_KEYS=(10_assess.sh 10a_assess_target.sql 10b_assess_facts.sql 06c_validate_cross_table.sql)
declare -A PIN=(
    [10_assess.sh]=067b7e4f11de389cb49caea4d902a547b6204c18c91f4d0e5d0306b4548870e5
    [10a_assess_target.sql]=b6b9da8d51099f03c4ca82b5f109b73bf0a0430202f15671f50ac6e554bc340a
    [10b_assess_facts.sql]=37809ddc91cc74a5bf7619dea032761b4e6ba64996444fd77d1f598db7637dab
    [06c_validate_cross_table.sql]=4c008824249f86bd2c1065c22eb32bea0687a2542d527ba2c21bdd71e6905708
)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTS_FILE=
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
declare -A F=()
fact() { printf '%s' "${F[$1]:-}"; }
load() { local k v; while IFS='|' read -r k v; do if [ -n "$k" ]; then F["$k"]=$v; fi; done; }
STATE_RESULT=absent
SOURCE=none
CODE=
REASONS=()

finish() {   # $1 = exit code
    CODE=$1
    echo "=== Finance Dashboard - Section 6 step 6b: trusted success record ==="
    echo "source run   : $SOURCE"
    echo "build        : refresh_time=$(fact built) result=$(fact run_result) committed=$(fact run_committed)"
    echo "in place     : refresh_time=$(fact live_stamp) assessment exit $(fact now_code)"
    echo "fingerprint  : build $(fact run_fp)"
    echo "               now   $(fact now_fp)"
    echo "existing     : $(fact old_present) refresh_time=$(fact old_built)"
    echo "------------------------------------------------------------"
    if [ -n "$(fact untrusted)" ]; then echo "  - ignored, not in the shape 12_refresh.sh creates: $(fact untrusted)"; fi
    for line in "${REASONS[@]}"; do echo "  - $line"; done
    echo "RECORD_STATE=$STATE_RESULT"
    echo "RECORD_SOURCE=$SOURCE"
    echo "RECORD_RESULT=$CODE"
    exit "$CODE"
}
usage() { CODE=2; echo "13_record_success.sh: $*" >&2; echo "RECORD_STATE=unchanged"; echo "RECORD_RESULT=2"; exit 2; }
on_exit() {  # an exit that did not pass through finish/usage is an unexpected abort
    local rc=$?
    if [ -z "$CODE" ]; then
        if [ -n "${STATE_DIR:-}" ]; then rm -f -- "${STATE_DIR:?}/state.json.new" 2>/dev/null || true; fi
        echo "13_record_success.sh: unexpected abort (exit $rc) - not a success; inspect $STATE_DIR by hand" >&2
        echo "RECORD_STATE=unknown"; echo "RECORD_RESULT=$rc"
    fi
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --facts) FACTS_FILE=${2:-}; [ -n "$FACTS_FILE" ] || usage "--facts needs a file"; shift 2 ;;
        --list-pins) CODE=0; for k in "${PIN_KEYS[@]}"; do printf '%s|%s\n' "$k" "${PIN[$k]}"; done; exit 0 ;;
        *) usage "unknown argument: $1" ;;
    esac
done
if [ -n "$FACTS_FILE" ]; then
    [ "$(id -u)" != 0 ] || usage "--facts is a test mode and never runs as root"
    [ -r "$FACTS_FILE" ] || usage "cannot read $FACTS_FILE"
    load < "$FACTS_FILE"
    STATE_DIR=$(fact test_state_dir)
    case "$STATE_DIR" in /?*) ;; *) usage "the facts name no absolute test_state_dir" ;; esac
    [ "$STATE_DIR" != /var/lib/fd-bootstrap ] || usage "a test never writes the real state folder"
else
    [ "$(id -u)" = 0 ] || usage "run with sudo: the state folder is root's"
fi
STATE="$STATE_DIR/state.json"
cd /

assess() {   # $1 = state file or "" -> exit code and FINGERPRINT_JSON (as key prefix $2)
    local out code=0
    if [ -n "$FACTS_FILE" ]; then return 0; fi
    if [ -n "$1" ]; then out=$(bash "$HERE/10_assess.sh" --state-file "$1" 2>&1) || code=$?
    else out=$(bash "$HERE/10_assess.sh" --state-file "$STATE_DIR/.none" 2>&1) || code=$?; fi
    F["$2_code"]=$code
    F["$2_fp"]=$(sed -n 's/^FINGERPRINT_JSON=//p' <<<"$out" | tail -n 1)
}

collect() {
    local k f newest
    for k in "${PIN_KEYS[@]}"; do
        if [ -f "$HERE/$k" ]; then F["sha:$k"]=$(sha256sum "$HERE/$k" | cut -d' ' -f1); else F["sha:$k"]=missing; fi
    done
    # the newest run folder 12_refresh.sh made that holds a fingerprint; a folder
    # of any other shape (owner, mode, symlink, file owner) is never a source
    f=
    F[untrusted]=
    for newest in $(ls -d "$RUN_GLOB_PREFIX"* 2>/dev/null); do
        if trusted_run "$newest"; then
            if grep -q '^RECORD_FINGERPRINT_JSON=' "$newest/result.txt"; then f="$newest/result.txt"; fi
        else
            F[untrusted]+="$newest "
        fi
    done
    F[run]=${f%/result.txt}
    if [ -n "$f" ]; then
        F[run_result]=$(sed -n 's/^RESULT=//p' "$f" | tail -n 1)
        F[run_committed]=$(sed -n 's/^TRANSACTION_COMMITTED=//p' "$f" | tail -n 1)
        F[run_fp]=$(sed -n 's/^RECORD_FINGERPRINT_JSON=//p' "$f" | tail -n 1)
        F[built]=$(sed -n 's/^ *refresh_time=\(.*\) postmaster_start=.*/\1/p' "$f" | tail -n 1)
    fi
    # later runs that ATTEMPTED a commit without a recorded success - every
    # folder counts here, trusted or not: this can only refuse, never accept
    F[later_attempts]=
    for newest in $(ls -d "$RUN_GLOB_PREFIX"* 2>/dev/null); do
        if [ -n "$f" ] && [[ ! "$newest" > "${f%/result.txt}" ]]; then continue; fi
        if grep -q '^FD4|commit|ATTEMPTED' "$newest/driver.out" 2>/dev/null; then F[later_attempts]+="$newest "; fi
    done
    assess "" now
    if [ "$(fact now_code)" = 0 ] || [ "$(fact now_code)" = 10 ]; then
        F[live_stamp]=$(sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on' psql -X -At \
            -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -p "$SOCKET_PORT" -d "$DATABASE" -c "$STAMP_SQL" 2>/dev/null || echo unreadable)
    fi
    if [ -f "$STATE" ]; then
        F[old_present]=yes
        F[old_fp]=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["last_success"]["fingerprint"]))' "$STATE" 2>/dev/null || echo unreadable)
        F[old_built]=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["last_success"].get("refresh_time",""))' "$STATE" 2>/dev/null || echo unreadable)
        assess "$STATE" old
    else
        F[old_present]=no
    fi
}

trusted_run() {   # $1 = run folder -> true only for the exact shape 12_refresh.sh creates
    python3 - "$1" "$RUN_OWNER" "$RUN_FILE_UID" <<'PY'
import os, pwd, stat, sys
d, owner, file_uid = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    st = os.lstat(d)
    ok = (stat.S_ISDIR(st.st_mode) and stat.S_IMODE(st.st_mode) == 0o750
          and pwd.getpwuid(st.st_uid).pw_name == owner)
    for name in ("result.txt", "driver.out"):
        f = os.lstat(os.path.join(d, name))
        ok = ok and stat.S_ISREG(f.st_mode) and f.st_uid == file_uid and not f.st_mode & 0o022
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
}

same_fp() {  # two fingerprint JSON texts -> true if the same six values
    python3 - "$1" "$2" <<'PY'
import json, sys
keys = ("uuid", "postmaster_start", "max_aml_id", "aml_n_tup_ins", "aml_n_tup_upd", "aml_n_tup_del")
try:
    a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
    ok = all(isinstance(a.get(k), str) and a.get(k) and a.get(k) == b.get(k) for k in keys)
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
}

invalidate_if_stale() {   # an existing record that no longer matches the layer is moved aside
    [ "$(fact old_present)" = yes ] || { STATE_RESULT=absent; return 0; }
    if [ "$(fact old_code)" = 0 ] && same_fp "$(fact old_fp)" "$(fact now_fp)" \
       && [[ $(fact live_stamp) =~ $RE_STAMP ]] && [ "$(fact old_built)" = "$(fact live_stamp)" ]; then
        STATE_RESULT=kept
        REASONS+=("the existing record still matches the layer in place (same fingerprint and refresh time, and the assessment says NOTHING TO DO with it) - kept")
        return 0
    fi
    if mv -f -- "$STATE" "${STATE_DIR:?}/state.json.invalid-$STAMP"; then
        STATE_RESULT=invalidated
        REASONS+=("the existing record no longer matches the layer in place - moved aside to state.json.invalid-$STAMP; backups are evidence-only until a build is recorded")
    else
        STATE_RESULT=unknown
        REASONS+=("the existing record is stale and could NOT be moved aside - check $STATE by hand")
        finish 64
    fi
}

refuse() {   # $1 = code, rest = reasons
    local code=$1; shift
    REASONS+=("$@")
    invalidate_if_stale
    finish "$code"
}

# ---- main --------------------------------------------------------------------
if [ -z "$FACTS_FILE" ]; then collect; fi
for k in "${PIN_KEYS[@]}"; do
    [ "$(fact "sha:$k")" = "${PIN[$k]}" ] || usage "$k does not match its approved hash - nothing changed"
done
SOURCE=${F[run]:-none}
[ -n "$(fact run)" ] || refuse 61 "no committed, verified refresh found - nothing to record"
{ [ "$(fact run_committed)" = yes ] && { [ "$(fact run_result)" = 0 ] || [ "$(fact run_result)" = 44 ]; }; } \
    || refuse 61 "the newest run with a fingerprint is not a committed, verified refresh (result $(fact run_result), committed $(fact run_committed))"
[ -z "$(fact later_attempts)" ] \
    || refuse 61 "a later refresh attempted a commit without a recorded success ($(fact later_attempts)) - the layer in place is not proven to be that build"
case "$(fact now_code)" in
    0|10) ;;
    *) refuse 63 "the assessment now exits $(fact now_code): the layer is missing, incomplete or not sound" ;;
esac
same_fp "$(fact run_fp)" "$(fact now_fp)" \
    || refuse 62 "the ledger fingerprint changed since that build (replacement, restart or ledger change)"
[[ $(fact built) =~ $RE_STAMP ]] \
    || refuse 62 "the build's refresh time could not be read from its result.txt ('$(fact built)') - the layer in place cannot be tied to that build"
[[ $(fact live_stamp) =~ $RE_STAMP ]] \
    || refuse 62 "the live refresh time could not be read ('$(fact live_stamp)': psql failed or no coverage row) - the layer in place cannot be tied to that build"
[ "$(fact built)" = "$(fact live_stamp)" ] \
    || refuse 62 "the layer in place (refresh time '$(fact live_stamp)') is not the one that build wrote ('$(fact built)')"

# write a candidate, prove it, then put it in place
if [ -z "$FACTS_FILE" ]; then mkdir_ok=$(install -d -o root -g root -m 0700 "$STATE_DIR" 2>&1 && echo yes || true)
else mkdir_ok=$(mkdir -p -m 0700 "$STATE_DIR" 2>&1 && echo yes || true); fi
[ "$mkdir_ok" = yes ] || refuse 64 "the state folder $STATE_DIR could not be created"
if ! ( umask 077; python3 - "$STATE_DIR/state.json.new" "$(fact run_fp)" "$(fact built)" "$SOURCE" <<'PY'
import json, os, sys
path, fp, built, source = sys.argv[1:5]
data = json.dumps({"last_success": {"fingerprint": json.loads(fp), "refresh_time": built, "source": source}}) + "\n"
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write(data); fh.flush(); os.fsync(fh.fileno())
PY
); then
    rm -f -- "${STATE_DIR:?}/state.json.new"
    refuse 64 "the candidate record could not be written"
fi
assess "$STATE_DIR/state.json.new" cand
if [ "$(fact cand_code)" != 0 ]; then
    rm -f -- "${STATE_DIR:?}/state.json.new"
    refuse 63 "with this record the assessment exits $(fact cand_code), not 0 NOTHING TO DO"
fi
# os.replace: atomic, and it fails (unlike mv) when state.json is a directory
if ! python3 -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$STATE_DIR/state.json.new" "$STATE"; then
    rm -f -- "${STATE_DIR:?}/state.json.new" || true
    refuse 64 "the record could not be put in place at $STATE"
fi
assess "$STATE" final
if [ -n "$FACTS_FILE" ]; then meta=$(fact test_final_meta); dmeta=$(fact test_dir_meta)
else meta=$(stat -c '%u:%a' "$STATE" 2>/dev/null || echo unreadable); dmeta=$(stat -c '%u:%a' "$STATE_DIR" 2>/dev/null || echo unreadable); fi
if [ "$(fact final_code)" != 0 ] || [ "$meta" != "0:600" ] || [ "$dmeta" != "0:700" ]; then
    mv -f -- "$STATE" "${STATE_DIR:?}/state.json.invalid-$STAMP" || true
    STATE_RESULT=invalidated
    REASONS+=("the record in place did not verify (assessment exit $(fact final_code), file $meta, folder $dmeta) - moved aside; no record is left")
    finish 64
fi
STATE_RESULT=written
REASONS+=("written and verified: the build, the layer in place and the ledger agree; the assessment says NOTHING TO DO with it")
finish 0
