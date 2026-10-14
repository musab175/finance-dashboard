#!/usr/bin/env bash
# 13_run_gate_test.sh - real-filesystem test of 13_record_success.sh's run-folder
# gate and source selection. Extracts trusted_run() and the selection block from
# the script UNCHANGED; only the expected owner/uid and the folder prefix are
# pointed at a scratch folder and the current user. Never needs root.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/13_record_success.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fd13gate.XXXXXX")
trap 'chmod -R u+w "${WORK:?}" 2>/dev/null; rm -rf -- "${WORK:?}"' EXIT
fn=$(awk '/^trusted_run\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$SCRIPT")
sel=$(awk '/# the newest run folder 12_refresh.sh made/{p=1} /assess "" now/{exit} p{print}' "$SCRIPT")
[ -n "$fn" ] && [ -n "$sel" ] || { echo "could not extract the gate from $SCRIPT"; exit 2; }
eval "$fn"
eval "select_run() { local f newest; $sel
}"
declare -A F=()
fact() { printf '%s' "${F[$1]:-}"; }
PASS=0 FAIL=0
ok()   { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS  $1"; else FAIL=$((FAIL+1)); echo "FAIL  $1: expected '$3', got '$2'"; fi; }
mkrun() {   # $1 = name, $2 = fingerprint yes|no, $3 = attempted yes|no
    local d="$WORK/r/fd_section4_refresh_$1"
    mkdir -p "$d"
    { echo "RESULT=0"; echo "TRANSACTION_COMMITTED=yes"
      if [ "$2" = yes ]; then echo "RECORD_FINGERPRINT_JSON={\"uuid\":\"$1\"}"; fi
      echo "                refresh_time=2026-10-15 04:10:0$((${#1} % 10)).000000 postmaster_start=x 06c=7/7"; } > "$d/result.txt"
    if [ "$3" = yes ]; then echo "FD4|commit|ATTEMPTED" > "$d/driver.out"; else : > "$d/driver.out"; fi
    chmod 0644 "$d/result.txt" "$d/driver.out"; chmod 0750 "$d"
}
reset() { rm -rf -- "${WORK:?}/r"; mkdir -p "$WORK/r"; F=(); }
RUN_GLOB_PREFIX="$WORK/r/fd_section4_refresh_"
RUN_OWNER=$(id -un); RUN_FILE_UID=$(id -u)
g() { if trusted_run "$1"; then echo trusted; else echo refused; fi; }

reset; mkrun 20261015T040000Z yes no; D="$WORK/r/fd_section4_refresh_20261015T040000Z"
ok "the shape 12_refresh.sh creates is trusted"            "$(g "$D")" trusted
chmod 0755 "$D";                ok "folder mode 0755 refused"   "$(g "$D")" refused; chmod 0750 "$D"
chmod 0770 "$D";                ok "folder mode 0770 refused"   "$(g "$D")" refused; chmod 0750 "$D"
chmod 0664 "$D/result.txt";     ok "group-writable result.txt refused" "$(g "$D")" refused; chmod 0644 "$D/result.txt"
chmod 0646 "$D/driver.out";     ok "world-writable driver.out refused" "$(g "$D")" refused; chmod 0644 "$D/driver.out"
mv "$D/driver.out" "$WORK/x";   ok "missing driver.out refused" "$(g "$D")" refused; mv "$WORK/x" "$D/driver.out"
mv "$D/result.txt" "$WORK/y"; ln -s "$WORK/y" "$D/result.txt"
                                ok "symlinked result.txt refused" "$(g "$D")" refused; rm "$D/result.txt"; mv "$WORK/y" "$D/result.txt"
ln -s "$D" "$WORK/r/fd_section4_refresh_20261015T050000Z"
                                ok "symlinked run folder refused" "$(g "$WORK/r/fd_section4_refresh_20261015T050000Z")" refused
rm "$WORK/r/fd_section4_refresh_20261015T050000Z"
RUN_OWNER=root;                 ok "folder of another owner refused" "$(g "$D")" refused; RUN_OWNER=$(id -un)
RUN_FILE_UID=0;                 ok "files of another owner refused"  "$(g "$D")" refused; RUN_FILE_UID=$(id -u)
ok "a nonexistent folder is refused"  "$(g "$WORK/r/none")" refused

reset; mkrun 20261015T040000Z yes no; mkrun 20261015T050000Z yes no; chmod 0755 "$WORK/r/fd_section4_refresh_20261015T050000Z"
select_run
ok "a newer planted folder with a fingerprint is never the source" "${F[run]##*_}" 20261015T040000Z
ok "and it is reported as ignored" "$(fact untrusted)" "$WORK/r/fd_section4_refresh_20261015T050000Z "
ok "its fingerprint is not read" "$(fact run_fp)" '{"uuid":"20261015T040000Z"}'

reset; mkrun 20261015T040000Z yes no; mkrun 20261015T050000Z no yes; chmod 0777 "$WORK/r/fd_section4_refresh_20261015T050000Z"
select_run
ok "an untrusted later folder that attempted a commit still refuses" "$(fact later_attempts)" "$WORK/r/fd_section4_refresh_20261015T050000Z "

reset; mkrun 20261015T040000Z yes no; mkrun 20261015T050000Z yes no
select_run
ok "the newest trusted folder with a fingerprint is the source" "${F[run]##*_}" 20261015T050000Z
ok "the build refresh time is parsed from that folder" "$(fact built)" "2026-10-15 04:10:06.000000"
ok "no later attempts after it" "$(fact later_attempts)" ""

reset; mkrun 20261015T040000Z no no
select_run
ok "no folder with a fingerprint: no source" "$(fact run)" ""

reset; select_run
ok "no run folders at all: no source" "$(fact run)" ""
echo "$((PASS+FAIL)) cases: $PASS PASS, $FAIL FAIL"
[ "$FAIL" = 0 ]
