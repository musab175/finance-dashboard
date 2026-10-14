# Section 6a: permanent storage for the bootstrap files (`/opt/fd-bootstrap`)

Applied on gft-odoo-report on 2026-10-14 by the operator. It replaced the temporary copies in `/tmp`. The
daily runbook still runs from `/tmp` until its cutover is approved separately.

## Layout

| Path | Owner | Mode | Named ACL entries (nothing else) |
|---|---|---|---|
| `/opt/fd-bootstrap` | root:root | 0700 (shown as 0750+) | ubuntu `r-x`, odoo `--x`, postgres `--x` |
| every file in it | root:root | 0600 (shown as 0640+) | ubuntu `r--` (all) |
| 00, 06b, 06c, 12b | | | + odoo `r--` (Section 4 driver opens them) |
| 06b, 06c, 07, 09d, 10a, 10b, 12c | | | + postgres `r--` (psql -f as postgres; 07 run as postgres; the Section 5 driver opens 09d, 06b, 06c) |
| `/var/backups/finance-dashboard` | root:root | 0700 (shown 0710) | postgres `--x` (07 writes its staging folder as postgres) |
| `/var/lib/fd-bootstrap/state.json` | root:root | 0600 in a root 0700 folder | none: the trusted success record (Section 5, decision A) |

- `group::---`, `other::---`, and no default ACL anywhere, so a file added later is root-only.
- `ls` shows the mask in the group column; the owning group's own entry is `---`.
- Only root can change anything.
- Groups are not used. `adm` also contains syslog and ocarun (the Oracle Cloud Agent's Run Command account),
  and they get nothing.

## The 24 files (SHA-256)

| File | SHA-256 |
|---|---|
| 00_guard_account_types.sql | fb699289b9b8496710c42b45255ce52cad5e66e386eaf757460f8c301d66114a |
| 06b_validate_live_inline.sql | dae76d6782878e646a970c980d09952e4715c07865f49a0afaadebb315e14f41 |
| 06c_validate_cross_table.sql | 4c008824249f86bd2c1065c22eb32bea0687a2542d527ba2c21bdd71e6905708 |
| 07_backup_reporting.sh | e72c757a1bd13672f98115c89670621fef0f735f4856959500fd1d909a5935c8 |
| 10_assess.sh | 067b7e4f11de389cb49caea4d902a547b6204c18c91f4d0e5d0306b4548870e5 |
| 10_assess_test.sh | 193e65519bb519cbb4613994f3ecd7dc7662527d04492c1cdbe6d1c21cc1e843 |
| 10a_assess_target.sql | b6b9da8d51099f03c4ca82b5f109b73bf0a0430202f15671f50ac6e554bc340a |
| 10b_assess_facts.sql | 37809ddc91cc74a5bf7619dea032761b4e6ba64996444fd77d1f598db7637dab |
| 11_install_module.sh | 9614282e0c1cdbd9b1889431bf2040890d9ff1c3df4e662645124fc19d231621 |
| 11_install_module_test.sh | e2b5fc419dea2ff29c0c5c8443987393a6a7760253b50c9aa521a5964fbeb21c |
| 12_refresh.sh | 5f194554856542aa49acf0f401d1cae88c1ffdc4563436b4468184ff873823e1 |
| 12_refresh_test.sh | 849912e4f88199260013b4ef310fd6f03e45ccc7375475d61e1120145a42ca8e |
| 12a_refresh_transaction.py | 848b1b2ea770326342e8d31d083d88021b725f9c9c2b0c7564bfba0929f59394 |
| 12a_refresh_transaction_test.py | 3ff1511ba690bd40ef741c94f6bd827a6942e781356ad2fd21fe6f6e05f323aa |
| 12b_clear_upsert_tables.sql | b8dc8c1fd6ec7b358cb53cbfd0d82f34b50175ff451a6c2e2c1942eddac0c32b |
| 12c_test_snapshot.sql | 9f8613904be982f471764342e27edb639cf0657d58d205b2fea9b186b884caf3 |
| 12d_verify_backup.sh | ba405fdcbd7303bf0c8de4993a2aab3dc14ed263c92e1b7f389054433987d980 |
| 09_restore_reporting.sh | 2af916b51014035c864e6a8d56d329ebdcc9ea1c178d25e92e05fce7689a1b62 |
| 09_restore_reporting_test.sh | b428867c9456ab715a64b861cbaa8ab71b8a86b7dd65ca09624d8c897ec4c18d |
| 09a_backup_with_record.sh | e8b9eed8fec4d573e5f4fcc855c22a1401b797bdabf7495564335b92d2afe039 |
| 09a_backup_with_record_test.sh | 9c49098ff720cd47772155445787c712545ad5338f80ea58470b529610b66ba7 |
| 09b_restore_transaction.py | 5b1fcf3afbdf2122914a35b50c59e3ca8367141116d942f5cc0fc5ee93302349 |
| 09b_restore_transaction_test.py | a56d8e9b4c961bdfa2a1a0bc9539b6f52621cb1e4100c8969d057eb939ad5732 |
| 09d_clear_all_tables.sql | 67d1e181ab7184832005e93bb3a57a018531ce4c9debf3f529e0064294edcdcf |

## Verification (read-only; run after any change, expected output shown)

ACL check: every entry of every path compared as a sorted set, plus "no other file":
```
D=/opt/fd-bootstrap; ALL="00_guard_account_types.sql 06b_validate_live_inline.sql 06c_validate_cross_table.sql 07_backup_reporting.sh 10_assess.sh 10_assess_test.sh 10a_assess_target.sql 10b_assess_facts.sql 11_install_module.sh 11_install_module_test.sh 12_refresh.sh 12_refresh_test.sh 12a_refresh_transaction.py 12a_refresh_transaction_test.py 12b_clear_upsert_tables.sql 12c_test_snapshot.sql 12d_verify_backup.sh 09_restore_reporting.sh 09_restore_reporting_test.sh 09a_backup_with_record.sh 09a_backup_with_record_test.sh 09b_restore_transaction.py 09b_restore_transaction_test.py 09d_clear_all_tables.sql"; OD="00_guard_account_types.sql 06b_validate_live_inline.sql 06c_validate_cross_table.sql 12b_clear_upsert_tables.sql"; PG="06b_validate_live_inline.sql 06c_validate_cross_table.sql 07_backup_reporting.sh 09d_clear_all_tables.sql 10a_assess_target.sql 10b_assess_facts.sql 12c_test_snapshot.sql"; exp=$({ printf '%s\n' "/opt|owner:root" "/opt|group:root" "/opt|user::rwx" "/opt|group::r-x" "/opt|other::r-x" "$D|owner:root" "$D|group:root" "$D|user::rwx" "$D|user:ubuntu:r-x" "$D|user:odoo:--x" "$D|user:postgres:--x" "$D|group::---" "$D|mask::r-x" "$D|other::---"; for f in $ALL; do printf '%s\n' "$D/$f|owner:root" "$D/$f|group:root" "$D/$f|user::rw-" "$D/$f|user:ubuntu:r--" "$D/$f|group::---" "$D/$f|mask::r--" "$D/$f|other::---"; done; for f in $OD; do echo "$D/$f|user:odoo:r--"; done; for f in $PG; do echo "$D/$f|user:postgres:r--"; done; } | LC_ALL=C sort); paths=(/opt "$D"); for f in $ALL; do paths+=("$D/$f"); done; act=$(sudo getfacl -p -E "${paths[@]}" 2>&1 | awk '/^# file: /{f=substr($0,9); next} /^# owner: /{print f "|owner:" substr($0,10); next} /^# group: /{print f "|group:" substr($0,10); next} NF{print f "|" $0}' | LC_ALL=C sort); extra=$(sudo find "$D" -mindepth 1 | LC_ALL=C sort | grep -v -x -F -f <(for f in $ALL; do echo "$D/$f"; done)); if [ "$exp" = "$act" ] && [ -z "$extra" ]; then echo "ACL_CHECK=PASS ($(printf '%s\n' "$act" | wc -l) entries on ${#paths[@]} paths as designed; no other file in $D)"; else diff <(printf '%s\n' "$exp") <(printf '%s\n' "$act") | sed -n 's/^</expected:/p; s/^>/found:   /p'; [ -z "$extra" ] || printf 'unexpected file: %s\n' $extra; echo "ACL_CHECK=FAIL"; fi
```
Expected: `ACL_CHECK=PASS (193 entries on 26 paths as designed; no other file in /opt/fd-bootstrap)`.

Effective access as ubuntu, odoo, postgres, syslog, ocarun, nobody:
```
D=/opt/fd-bootstrap; ALL="00_guard_account_types.sql 06b_validate_live_inline.sql 06c_validate_cross_table.sql 07_backup_reporting.sh 10_assess.sh 10_assess_test.sh 10a_assess_target.sql 10b_assess_facts.sql 11_install_module.sh 11_install_module_test.sh 12_refresh.sh 12_refresh_test.sh 12a_refresh_transaction.py 12a_refresh_transaction_test.py 12b_clear_upsert_tables.sql 12c_test_snapshot.sql 12d_verify_backup.sh 09_restore_reporting.sh 09_restore_reporting_test.sh 09a_backup_with_record.sh 09a_backup_with_record_test.sh 09b_restore_transaction.py 09b_restore_transaction_test.py 09d_clear_all_tables.sql"; OD="00_guard_account_types.sql 06b_validate_live_inline.sql 06c_validate_cross_table.sql 12b_clear_upsert_tables.sql"; PG="06b_validate_live_inline.sql 06c_validate_cross_table.sql 07_backup_reporting.sh 09d_clear_all_tables.sql 10a_assess_target.sql 10b_assess_facts.sql 12c_test_snapshot.sql"; U="ubuntu odoo postgres syslog ocarun nobody"; bad=0; printf '%-32s' path; for u in $U; do printf ' %-9s' "$u"; done; echo; for p in "$D" $(for f in $ALL; do echo "$D/$f"; done); do n=${p#$D/}; [ "$p" = "$D" ] && n="(the folder)"; line=$(printf '%-32s' "$n"); for u in $U; do got=; sudo -u "$u" test -r "$p" && got=r; sudo -u "$u" test -w "$p" && got=${got}w; sudo -u "$u" test -x "$p" && got=${got}x; got=${got:--}; want=-; if [ "$p" = "$D" ]; then case $u in ubuntu) want=rx;; odoo|postgres) want=x;; esac; else case $u in ubuntu) want=r;; odoo) case " $OD " in *" $n "*) want=r;; esac;; postgres) case " $PG " in *" $n "*) want=r;; esac;; esac; fi; if [ "$got" = "$want" ]; then line="$line $(printf '%-9s' "$got")"; else line="$line $(printf '%-9s' "$got!=$want")"; bad=$((bad+1)); fi; done; echo "$line"; done; if [ "$bad" = 0 ]; then echo "ACCESS_MATRIX=PASS (the folder and 24 files x 6 accounts: every result as designed)"; else echo "ACCESS_MATRIX=FAIL ($bad unexpected, shown as found!=expected)"; fi
```
Expected: `ACCESS_MATRIX=PASS (the folder and 24 files x 6 accounts: every result as designed)`.

Backup store:
```
D=/var/backups/finance-dashboard; namei -l "$D"; stat -c '%U:%G %a %F' "$D"; exp=$(printf '%s\n' "owner:root" "group:root" "user::rwx" "user:postgres:--x" "group::---" "mask::--x" "other::---" | LC_ALL=C sort); act=$(sudo getfacl -p -E "$D" 2>&1 | awk '/^# file: /{next} /^# owner: /{print "owner:" substr($0,10); next} /^# group: /{print "group:" substr($0,10); next} NF{print}' | LC_ALL=C sort); if [ "$exp" = "$act" ]; then echo "STORE_ACL=PASS (exactly root rwx, postgres pass-through, nothing else, no default entries)"; else diff <(printf '%s\n' "$exp") <(printf '%s\n' "$act") | sed -n 's/^</expected:/p; s/^>/found:   /p'; echo "STORE_ACL=FAIL"; fi; bad=0; for u in postgres ubuntu odoo syslog ocarun nobody; do got=; sudo -u "$u" test -r "$D" && got=r; sudo -u "$u" test -w "$D" && got=${got}w; sudo -u "$u" test -x "$D" && got=${got}x; got=${got:--}; want=-; [ "$u" = postgres ] && want=x; [ "$got" = "$want" ] || bad=$((bad+1)); echo "$u: $got (expected $want)"; done; [ "$bad" = 0 ] && echo "STORE_ACCESS=PASS" || echo "STORE_ACCESS=FAIL ($bad unexpected)"
```
Expected: `STORE_ACL=PASS`, `STORE_ACCESS=PASS`.

## How it was applied (2026-10-14)

1. The 24 sources were hash-checked at their staging paths (24/24 OK).
2. Copied in: `sudo mkdir -m 0700 /opt/fd-bootstrap && sudo install -o root -g root -m 0600 <the 24 files> /opt/fd-bootstrap/`.
3. The copies were hash-checked again (24/24 OK).
4. Access was granted with:
   - `setfacl -m u:ubuntu:rx,u:odoo:x,u:postgres:x` on the folder;
   - `u:ubuntu:r` on all 24 files;
   - `u:odoo:r` on the 4 files odoo needs;
   - `u:postgres:r` on the 7 files postgres needs.

## Evidence on gft-odoo-report (2026-10-14)

- **The ACL check and the access matrix:** `ACL_CHECK=PASS (193 entries on 26 paths …)` and `ACCESS_MATRIX=PASS`.
- **Functional, from `/opt` as ubuntu:**
  - files 12/12; no "Permission denied";
  - suites 40/35/79/64/64/233/106, all passing;
  - the driver's Python is 3.12.3 with psycopg2 2.9.10 (Ubuntu's own package).
- **The backup store:** `STORE_ACL=PASS`, `STORE_ACCESS=PASS`.
- **E6** ran from `/opt/fd-bootstrap` and passed (see the Section 5 commit).

## Rollback

- `sudo rm -rf /opt/fd-bootstrap`. The ACLs go with the files.
- `sudo rmdir /var/backups/finance-dashboard`, which works only while the folder is empty.
- The `acl` package (2.3.2-1build1.1) stays unless removed separately.
