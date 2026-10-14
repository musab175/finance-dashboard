#!/usr/bin/env bash
# =============================================================================
# 09a_backup_with_record_test.sh - controlled tests for 09a_backup_with_record.sh.
# 2026-10-14.
#
# MADE-UP FACTS ONLY. No database, no Odoo, no sudo. Each case builds a scratch
# store, with - where the case gets that far - the folder 12d would leave (a
# small stand-in archive, 07_output.txt, archive_listing.txt) and 12d's output
# for it, writes the facts, and runs
#   bash 09a_backup_with_record.sh --facts FILE
#
# Every case checks FIVE things: the exit code; what the store holds afterwards
# (the final fd_backup_ folder, a FAILED_ folder, the untouched 12d folder, or
# nothing); whether a record.json exists; how many register lines there are;
# BACKUP_RESTORABLE. Cases that end in 0 or 57 also check the record's content
# and the folder's modes. So a refusal is proven to create nothing, and a failed
# backup is proven never to get a record or a register line.
# Usage:  bash 09a_backup_with_record_test.sh      exit 0 only if every case passes
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/09a_backup_with_record.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STAMP=20261015T081500Z
ARCHIVE=fd_reporting_gftuae_$STAMP.dump
FP='{"uuid": "629148b0-9f15-11ee-bf49-2569bf801689", "postmaster_start": "2026-10-14T14:03:11.123456Z", "max_aml_id": "30123456", "aml_n_tup_ins": "100", "aml_n_tup_upd": "7", "aml_n_tup_del": "0"}'
FP_OTHER='{"uuid": "629148b0-9f15-11ee-bf49-2569bf801689", "postmaster_start": "2026-10-14T14:03:11.123456Z", "max_aml_id": "30123457", "aml_n_tup_ins": "101", "aml_n_tup_upd": "7", "aml_n_tup_del": "0"}'
FP_SHORT='{"uuid": "629148b0-9f15-11ee-bf49-2569bf801689", "postmaster_start": "2026-10-14T14:03:11.123456Z"}'
REFRESH_TIME='2026-10-15 07:58:21.402113'
STATE_SHA=aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11
PINS=$(bash "$TOOL" --list-pins)
H() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }   # a made-up 64-hex value

STORE_OK='/:0:755:d;/var:0:755:d;/var/backups:0:755:d;/var/backups/finance-dashboard:0:710:d'
STATE_OK='/:0:755:d;/var:0:755:d;/var/lib:0:755:d;/var/lib/fd-bootstrap:0:700:d;/var/lib/fd-bootstrap/state.json:0:600:f'
REG_OK='/:0:755:d;/var:0:755:d;/var/backups:0:755:d;/var/backups/finance-dashboard:0:710:d;/var/backups/finance-dashboard/register.tsv:0:600:f'

base_facts() {    # $1 = store, $2 = 12d output file
    sed 's/^/file_sha:/' <<<"$PINS"
    cat <<EOF
hostname|gft-odoo-report
self_sha|$(H self)
odoo_service|inactive
odoo_processes|0
store_chain|$STORE_OK
store_pg_traverse|true
store_pg_list|false
register_chain|absent
state_chain|$STATE_OK
state_sha_before|$STATE_SHA
state_sha_after|$STATE_SHA
state_fp|$FP
a1_code|0
a1_verdict|NOTHING TO DO
a1_fp|$FP
a1_reasons|module installed; layer complete, correct and consistent
a2_code|0
a2_verdict|NOTHING TO DO
a2_fp|$FP
a2_reasons|module installed; layer complete, correct and consistent
test_store|$1
test_d12_rc|0
test_d12_output|$2
test_archive_stamp|$REFRESH_TIME
live_stamp|$REFRESH_TIME
EOF
}

COLS_DAILY='(id, company_id, date, sales, cogs, opex, other_income, depreciation, sales_ic, cogs_ic, cash_bank_delta, ar_delta, ap_delta, ar_ic_delta, ap_ic_delta, other_current_assets_delta, other_current_liabilities_delta, other_current_assets_ic_delta, other_current_liabilities_ic_delta, create_uid, create_date, write_uid, write_date)'
COLS_ARAP='(id, company_id, partner_id, date, date_maturity, is_intercompany, ar_amount, ap_amount, create_uid, create_date, write_uid, write_date)'
COLS_AGING='(id, company_id, date, date_maturity, ar_amount, ap_amount)'
COLS_EXP='(id, company_id, account_id, date, amount, create_uid, create_date, write_uid, write_date)'
COLS_COV='(id, company_id, covered_from, covered_to, dirty_from, last_refresh_at, last_refresh_ok, create_uid, create_date, write_uid, write_date)'

d12_output() {    # $1 = store, $2 = archive sha, $3 = archive bytes; then edits by the case
    local dir="$1/fd_section4_backup_$STAMP"
    cat <<EOF
=== Finance Dashboard - Section 4 test aid: backup evidence E1-E4 ===
target      : socket /var/run/postgresql port 5432 database gftuae (as postgres)
backup tool : 07_backup_reporting.sh e72c757a1bd13672f98115c89670621fef0f735f4856959500fd1d909a5935c8 (pinned, unchanged)
folder      : $dir
PASS  E1 completed: 07 exited 0; $ARCHIVE, $3 bytes, sha256 $2
PASS  E2 scope: definitions and data for exactly the five reporting tables; sequences: public.finance_dashboard_daily_id_seq
PASS  E3 readable: finance_dashboard_daily - columns $COLS_DAILY
PASS  E4 exact: finance_dashboard_daily - 8756 rows, archive = live, sha256 $(H daily)
PASS  E3 readable: finance_dashboard_arap_daily - columns $COLS_ARAP
PASS  E4 exact: finance_dashboard_arap_daily - 506202 rows, archive = live, sha256 $(H arap)
PASS  E3 readable: finance_dashboard_aging_daily - columns $COLS_AGING
PASS  E4 exact: finance_dashboard_aging_daily - 39805 rows, archive = live, sha256 $(H aging)
PASS  E3 readable: finance_dashboard_expense_daily - columns $COLS_EXP
PASS  E4 exact: finance_dashboard_expense_daily - 17747 rows, archive = live, sha256 $(H expense)
PASS  E3 readable: finance_dashboard_coverage - columns $COLS_COV
PASS  E4 exact: finance_dashboard_coverage - 9 rows, archive = live, sha256 $(H coverage)
------------------------------------------------------------
kept        : $ARCHIVE, 07_output.txt, archive_listing.txt in $dir
not proven  : E5 (which ledger copy - Section 6) and E6 (a restore - Section 5)
BACKUP_EVIDENCE=PASS
EOF
}

n=0 failures=0
OUT= RC=
# case_ EXIT STORE_STATE RECORD REGISTER_LINES RESTORABLE "name" WITH_FOLDER [fact overrides...]
#   STORE_STATE: final | failed | d12 (12d's folder untouched) | empty
#   WITH_FOLDER: yes = the 12d folder exists (the case reaches the backup); no = it does not
#   overrides: 'key|value' facts, or one of the special edits below
case_() {
    local want_code=$1 want_store=$2 want_record=$3 want_reg=$4 want_rest=$5 name=$6 with=$7
    shift 7
    n=$((n + 1))
    local cdir="$WORK/c$n" store="$WORK/c$n/store" d12 sha bytes facts got_store=empty got_record=no got_reg=0 got_rest
    mkdir -p "$store"
    d12="$store/fd_section4_backup_$STAMP"
    local -a overrides=() edits=()
    local o
    for o in "$@"; do
        case "$o" in @*) edits+=("$o") ;; *) overrides+=("$o") ;; esac
    done
    if [ "$with" = yes ]; then
        mkdir -m 0750 "$d12"
        printf 'stand-in archive for case %s\n' "$n" > "$d12/$ARCHIVE"
        printf '07 output\n' > "$d12/07_output.txt"
        printf 'listing\n' > "$d12/archive_listing.txt"
    fi
    sha=$( [ -f "$d12/$ARCHIVE" ] && sha256sum "$d12/$ARCHIVE" | awk '{print $1}' || echo none )
    bytes=$( [ -f "$d12/$ARCHIVE" ] && wc -c < "$d12/$ARCHIVE" | tr -d ' ' || echo 0 )
    d12_output "$store" "$sha" "$bytes" > "$cdir/d12.txt"
    facts="$cdir/facts.txt"
    base_facts "$store" "$cdir/d12.txt" > "$facts"
    for o in "${overrides[@]}"; do printf '%s\n' "$o" >> "$facts"; done
    for o in "${edits[@]}"; do edit "$o" "$cdir" "$store" "$d12"; done
    RC=0
    OUT=$(bash "$TOOL" --facts "$facts" 2>&1) || RC=$?
    # what the store holds now
    if [ -d "$store/FAILED_fd_backup_$STAMP" ]; then got_store=failed
    elif [ -d "$store/fd_backup_$STAMP" ]; then got_store=final
    elif [ -d "$d12" ]; then got_store=d12
    elif [ -n "$(ls -A "$store" | grep -v '^register.tsv$' | grep -v '^PRE_' || true)" ]; then got_store=other
    fi
    if [ -f "$store/fd_backup_$STAMP/record.json" ] || [ -f "$store/FAILED_fd_backup_$STAMP/record.json" ] \
       || [ -f "$d12/record.json" ]; then got_record=yes; fi
    if [ -f "$store/register.tsv" ]; then got_reg=$(grep -vc '^#' "$store/register.tsv" || true); fi
    got_rest=$(awk -F= '/^BACKUP_RESTORABLE=/ {print $2}' <<<"$OUT")
    local ok=yes extra=
    [ "$RC" = "$want_code" ] || ok=no
    [ "$got_store" = "$want_store" ] || ok=no
    [ "$got_record" = "$want_record" ] || ok=no
    [ "$got_reg" = "$want_reg" ] || ok=no
    [ "$got_rest" = "$want_rest" ] || ok=no
    if [ "$ok" = yes ] && { [ "$RC" = 0 ] || [ "$RC" = 57 ]; }; then
        local want_stamp
        want_stamp=$(awk -F'|' '$1 == "test_archive_stamp" {v = $2} END {print v}' "$facts")
        extra=$(check_record "$store/fd_backup_$STAMP" "$want_rest" "$want_stamp") || ok=no
    fi
    if [ "$RC" != 0 ] && [ "$RC" != 57 ] && grep -qE '^BACKUP_(ARCHIVE|RECORD)_SHA256=|^record       :' <<<"$OUT"; then
        ok=no extra="a failed or refused run printed a hash marker or a record line"
    fi
    if [[ " ${edits[*]-} " == *" @dest-exists "* ]] \
       && { [ ! -f "$store/fd_backup_$STAMP/keep.txt" ] || [ -e "$store/fd_backup_$STAMP/record.json" ]; }; then
        ok=no extra="the folder that already existed was changed"
    fi
    if [ "$ok" = yes ]; then
        printf 'PASS  %2s  %-62s %s\n' "$RC" "$name" "$extra"
    else
        printf 'FAIL  %2s  %-62s want %s/%s/%s/%s/%s got %s/%s/%s/%s/%s %s\n' "$RC" "$name" \
            "$want_code" "$want_store" "$want_record" "$want_reg" "$want_rest" \
            "$RC" "$got_store" "$got_record" "$got_reg" "$got_rest" "$extra"
        printf '%s\n' "$OUT" | sed 's/^/        | /' | tail -n 25
        failures=$((failures + 1))
    fi
}

edit() {          # special edits: change the 12d output or the folder after it was built
    local e=$1 cdir=$2 store=$3 d12=$4
    case "$e" in
        @no-folder)       rm -rf "$d12"; sed -i.bak '/^folder      : /d; /^PASS/d; s/^BACKUP_EVIDENCE=PASS$/12d_verify_backup.sh: BACKUP CHECK ERROR: could not create the folder/' "$cdir/d12.txt" ;;
        @d12-fail)        sed -i.bak 's/^PASS  E4 exact: finance_dashboard_aging_daily - .*/FAIL  E4 exact: finance_dashboard_aging_daily - archive 39805 rows abc..., live 39806 rows def.../; s/^BACKUP_EVIDENCE=PASS$/BACKUP_EVIDENCE=FAIL/' "$cdir/d12.txt" ;;
        @fail-line-only)  sed -i.bak '/^PASS  E2 scope/a\
FAIL  E2 scope: tables [x] data [y]' "$cdir/d12.txt" ;;
        @four-e4)         sed -i.bak '/^PASS  E4 exact: finance_dashboard_expense_daily/d' "$cdir/d12.txt" ;;
        @dup-e4)          sed -i.bak '/^PASS  E4 exact: finance_dashboard_coverage/p' "$cdir/d12.txt" ;;
        @odd-table)       sed -i.bak 's/^PASS  E4 exact: finance_dashboard_coverage - /PASS  E4 exact: finance_dashboard_category_sales_daily - /' "$cdir/d12.txt" ;;
        @trailing-line)   printf 'something after the evidence line\n' >> "$cdir/d12.txt" ;;
        @two-e1)          sed -i.bak '/^PASS  E1 completed/p' "$cdir/d12.txt" ;;
        @archive-changed) printf 'changed after E1\n' >> "$d12/$ARCHIVE" ;;
        @archive-bytes)   sed -i.bak "s/, [0-9]* bytes, /, 1 bytes, /" "$cdir/d12.txt" ;;
        @archive-same-size) printf 'X' | dd of="$d12/$ARCHIVE" bs=1 seek=0 conv=notrunc 2>/dev/null ;;
        @extra-file)      printf 'x\n' > "$d12/data_finance_dashboard_daily.sql" ;;
        @dest-exists)     mkdir "$store/fd_backup_$STAMP"; printf 'older\n' > "$store/fd_backup_$STAMP/keep.txt" ;;
        @folder-elsewhere) sed -i.bak "s#^folder      : .*#folder      : /tmp/fd_section4_backup_$STAMP#" "$cdir/d12.txt"; rm -rf "$d12" ;;
        @register-exists) printf '# created_utc\tfolder\tresult\trestorable\tarchive_sha256\trecord_sha256\n2026-10-14T08:00:00Z\tfd_backup_20261014T080000Z\t0\tyes\t%s\t%s\n' "$(H a)" "$(H r)" > "$store/register.tsv"; chmod 600 "$store/register.tsv"; echo "register_chain|$REG_OK" >> "$cdir/facts.txt" ;;
        *) echo "unknown edit $e" >&2; exit 2 ;;
    esac
}

check_record() {  # $1 = final folder, $2 = yes|no restorable, $3 = refresh time -> "" or the problem (exit 1)
    python3 - "$1" "$2" "$FP" "$3" "$ARCHIVE" <<'PY'
import hashlib, json, os, stat, sys
folder, want_rest, fp, refresh, archive = sys.argv[1:6]
problems = []
rec_path = os.path.join(folder, "record.json")
data = open(rec_path, "rb").read()
rec = json.loads(data)
names = sorted(os.listdir(folder))
if names != sorted([archive, "07_output.txt", "archive_listing.txt", "12d_output.txt", "record.json"]):
    problems.append("folder holds %s" % names)
if stat.S_IMODE(os.stat(folder).st_mode) != 0o700:
    problems.append("folder mode %o" % stat.S_IMODE(os.stat(folder).st_mode))
for n in names:
    m = stat.S_IMODE(os.stat(os.path.join(folder, n)).st_mode)
    if m != 0o400:
        problems.append("%s mode %o" % (n, m))
arch = open(os.path.join(folder, archive), "rb").read()
checks = [
    ("record_version", rec.get("record_version") == 1),
    ("test flag", rec.get("test") is True),
    ("restorable", rec.get("restorable") is (want_rest == "yes")),
    ("fingerprint", rec.get("fingerprint") == json.loads(fp)),
    ("refresh time", rec.get("layer_refresh_time") == refresh),
    ("archive sha256", rec["archive"]["sha256"] == hashlib.sha256(arch).hexdigest()),
    ("archive bytes", rec["archive"]["bytes"] == len(arch)),
    ("archive file", rec["archive"]["file"] == archive),
    ("five tables", list(rec["tables"]) == ["finance_dashboard_daily", "finance_dashboard_arap_daily",
                                             "finance_dashboard_aging_daily", "finance_dashboard_expense_daily",
                                             "finance_dashboard_coverage"]),
    ("rows", [t["rows"] for t in rec["tables"].values()] == [8756, 506202, 39805, 17747, 9]),
    ("hashes", all(len(t["copy_sha256"]) == 64 for t in rec["tables"].values())),
    ("coverage columns", "last_refresh_at" in rec["tables"]["finance_dashboard_coverage"]["columns"]),
    ("tools", len(rec["tools"]) == 7 and "09a_backup_with_record.sh" in rec["tools"]),
    ("assessments", rec["assessment_before"]["exit"] == rec["assessment_after"]["exit"]),
    ("reasons", len(rec["reasons"]) >= 1),
    ("host", rec.get("host") == "gft-odoo-report" and rec.get("database") == "gftuae"),
]
problems += ["record: " + name for name, ok in checks if not ok]
reg = open(os.path.join(os.path.dirname(folder), "register.tsv")).read().splitlines()
last = reg[-1].split("\t")
if last[1] != os.path.basename(folder) or last[4] != rec["archive"]["sha256"] \
        or last[5] != hashlib.sha256(data).hexdigest() or last[3] != want_rest:
    problems.append("register line %s" % last)
if stat.S_IMODE(os.stat(os.path.join(os.path.dirname(folder), "register.tsv")).st_mode) != 0o600:
    problems.append("register mode")
if problems:
    print("; ".join(problems)); sys.exit(1)
print("record ok")
PY
}

# ---- usable backups -----------------------------------------------------------------------------
case_  0 final  yes 1 yes "NOTHING TO DO twice, trusted state: RESTORABLE"            yes
case_  0 final  yes 2 yes "a second backup: the register gets one more line"          yes @register-exists
case_ 57 final  yes 1 no  "REFRESH: verified, EVIDENCE ONLY"                           yes 'a1_code|10' 'a1_verdict|REFRESH' 'a1_reasons|changed since the last successful build: max_aml_id 30123455 -> 30123456' 'a2_code|10' 'a2_verdict|REFRESH'
case_ 57 final  yes 1 no  "REFRESH with empty tables: no refresh time, still evidence" yes 'a1_code|10' 'a1_verdict|REFRESH' 'a1_reasons|empty table(s): finance_dashboard_coverage' 'a2_code|10' 'a2_verdict|REFRESH' 'test_archive_stamp|' 'live_stamp|'
case_ 57 final  yes 1 no  "state file owned by ubuntu: not trusted"                   yes 'state_chain|/:0:755:d;/tmp:0:1777:d;/tmp/fd_section4:1001:755:d;/tmp/fd_section4/state_test_live.json:1001:664:f'
case_ 57 final  yes 1 no  "state file root's but in a world-writable folder"          yes 'state_chain|/:0:755:d;/tmp:0:1777:d;/tmp/state.json:0:600:f'
case_ 57 final  yes 1 no  "state file group-writable"                                 yes "state_chain|/:0:755:d;/var:0:755:d;/var/lib:0:755:d;/var/lib/fd-bootstrap:0:700:d;/var/lib/fd-bootstrap/state.json:0:660:f"
case_ 57 final  yes 1 no  "a symbolic link on the state file's path"                  yes "state_chain|/:0:755:d;/var:0:755:d;/var/lib:0:777:l;/var/lib/fd-bootstrap:0:700:d;/var/lib/fd-bootstrap/state.json:0:600:f"
case_ 57 final  yes 1 no  "state file missing (the assessment says REFRESH)"          yes "state_chain|/:0:755:d;/var:0:755:d;/var/lib:0:755:d;/var/lib/fd-bootstrap:-:-:missing" 'state_sha_before|missing' 'state_sha_after|missing' 'state_fp|' 'a1_code|10' 'a1_verdict|REFRESH' 'a2_code|10' 'a2_verdict|REFRESH'
# ---- refused: nothing is created ----------------------------------------------------------------
for key in $(cut -d'|' -f1 <<<"$PINS"); do
    case_ 55 empty no 0 no "pin mismatch: $key" no "file_sha:$key|$(H wrong)"
done
case_ 55 empty no 0 no "pin missing: 12d_verify_backup.sh"                             no 'file_sha:12d_verify_backup.sh|missing'
case_ 55 empty no 0 no "Odoo service active"                                          no 'odoo_service|active'
case_ 55 empty no 0 no "Odoo service state unknown"                                   no 'odoo_service|'
case_ 55 empty no 0 no "Odoo processes running"                                       no 'odoo_processes|2'
case_ 55 empty no 0 no "store owned by ubuntu"                                        no 'store_chain|/:0:755:d;/var:0:755:d;/var/backups:0:755:d;/var/backups/finance-dashboard:1001:700:d'
case_ 55 empty no 0 no "store readable by its group (0750)"                           no 'store_chain|/:0:755:d;/var:0:755:d;/var/backups:0:755:d;/var/backups/finance-dashboard:0:750:d'
case_ 55 empty no 0 no "store open to others (0711)"                                  no 'store_chain|/:0:755:d;/var:0:755:d;/var/backups:0:755:d;/var/backups/finance-dashboard:0:711:d'
case_ 55 empty no 0 no "a parent of the store writable by others"                     no 'store_chain|/:0:755:d;/var:0:755:d;/var/backups:0:777:d;/var/backups/finance-dashboard:0:710:d'
case_ 55 empty no 0 no "store is a symbolic link"                                     no 'store_chain|/:0:755:d;/var:0:755:d;/var/backups:0:755:d;/var/backups/finance-dashboard:0:777:l'
case_ 55 empty no 0 no "store missing"                                                no 'store_chain|/:0:755:d;/var:0:755:d;/var/backups:0:755:d;/var/backups/finance-dashboard:-:-:missing'
case_ 55 empty no 0 no "postgres cannot pass through the store"                       no 'store_pg_traverse|false'
case_ 55 empty no 0 no "postgres can list the store"                                  no 'store_pg_list|true'
case_ 55 empty no 0 no "register mode 644"                                            no "register_chain|${REG_OK%600:f}644:f"
case_ 55 empty no 0 no "register owned by ubuntu"                                     no "register_chain|${REG_OK%0:600:f}1001:600:f"
case_ 55 empty no 0 no "assessment 11 INSTALL + REFRESH"                              no 'a1_code|11' 'a1_verdict|INSTALL + REFRESH'
case_ 55 empty no 0 no "assessment 20 wrong target"                                   no 'a1_code|20' 'a1_verdict|STOP: wrong target'
case_ 55 empty no 0 no "assessment 21 pending modules"                                no 'a1_code|21' 'a1_verdict|STOP: pending modules'
case_ 55 empty no 0 no "assessment 22 layer anomaly (e.g. a table missing)"           no 'a1_code|22' 'a1_verdict|STOP: layer anomaly'
case_ 55 empty no 0 no "assessment 2 ERROR"                                           no 'a1_code|2' 'a1_verdict|ERROR'
case_ 55 empty no 0 no "assessment exit 99"                                           no 'a1_code|99' 'a1_verdict|'
case_ 55 empty no 0 no "exit 0 but verdict REFRESH (inconsistent)"                    no 'a1_verdict|REFRESH'
case_ 55 empty no 0 no "NOTHING TO DO without a complete fingerprint"                 no "a1_fp|$FP_SHORT"
case_ 55 empty no 0 no "REFRESH without a fingerprint"                                no 'a1_code|10' 'a1_verdict|REFRESH' 'a1_fp|'
# ---- created but not usable: FAILED_, no record, no register line -------------------------------
case_ 56 failed no 0 no "12d: an E4 mismatch, BACKUP_EVIDENCE=FAIL"                   yes 'test_d12_rc|1' @d12-fail
case_ 56 failed no 0 no "12d: exit 0 but a FAIL line"                                 yes @fail-line-only
case_ 56 failed no 0 no "12d: only four E4 lines"                                     yes @four-e4
case_ 56 failed no 0 no "12d: one table's E4 twice"                                   yes @dup-e4
case_ 56 failed no 0 no "12d: E4 for a table outside the five"                        yes @odd-table
case_ 56 failed no 0 no "12d: two E1 lines"                                           yes @two-e1
case_ 56 failed no 0 no "12d: a line after BACKUP_EVIDENCE=PASS"                      yes @trailing-line
case_ 56 failed no 0 no "12d exit 1 although every line passed"                       yes 'test_d12_rc|1'
case_ 56 failed no 0 no "archive changed after E1 hashed it"                          yes @archive-changed
case_ 56 failed no 0 no "archive size differs from E1"                                yes @archive-bytes
case_ 56 failed no 0 no "archive changed after E1, same size: only the hash shows it" yes @archive-same-size
case_ 56 failed no 0 no "an extra file in the folder"                                 yes @extra-file
case_ 56 failed no 0 no "assessment 2 exit code differs"                              yes 'a2_code|10' 'a2_verdict|REFRESH'
case_ 56 failed no 0 no "assessment 2 fingerprint differs (a ledger write)"           yes "a2_fp|$FP_OTHER"
case_ 56 failed no 0 no "state file changed during the backup"                        yes "state_sha_after|$(H other)"
case_ 56 failed no 0 no "live refresh time differs from the archive's"                yes 'live_stamp|2026-10-15 08:30:00.000000'
case_ 56 failed no 0 no "NOTHING TO DO but the archive has no refresh time"           yes 'test_archive_stamp|' 'live_stamp|'
case_ 56 failed no 0 no "fd_backup_<UTC> already exists: never overwritten"           yes @dest-exists
case_ 56 empty  no 0 no "12d reports a folder outside the store: not touched"         yes @folder-elsewhere
# ---- could not run: nothing created -------------------------------------------------------------
case_  2 empty no 0 no "12d created no folder (exit 2)"                               no 'test_d12_rc|2' @no-folder
echo "------------------------------------------------------------"
# argument errors and the real-mode guard
arg_case() {      # want "name" args...
    local want=$1 name=$2; shift 2
    n=$((n + 1)); RC=0
    OUT=$(bash "$TOOL" "$@" 2>&1) || RC=$?
    if [ "$RC" = "$want" ] && grep -q '^BACKUP_RESULT=2$' <<<"$OUT"; then
        printf 'PASS  %2s  %-62s\n' "$RC" "$name"
    else
        printf 'FAIL  %2s  %-62s\n' "$RC" "$name"; printf '%s\n' "$OUT" | sed 's/^/        | /'
        failures=$((failures + 1))
    fi
}
mkdir -p "$WORK/args"; base_facts "$WORK/args" /dev/null > "$WORK/args/f.txt"
arg_case 2 "no --facts and not root: run with sudo"                          
arg_case 2 "unknown argument"                                                 --live
arg_case 2 "--state-file relative"                                            --state-file state.json --facts "$WORK/args/f.txt"
arg_case 2 "--state-file without a value"                                     --state-file
arg_case 2 "--facts with a missing file"                                      --facts "$WORK/args/none.txt"
printf 'test_store|/var/backups/finance-dashboard\n' >> "$WORK/args/f.txt"
arg_case 2 "a test naming the real store"                                     --facts "$WORK/args/f.txt"
echo "------------------------------------------------------------"
echo "$n cases: $((n - failures)) PASS, $failures FAIL"
[ "$failures" = 0 ]
