-- SECTION 2 ASSESSMENT, PART A: WHICH SERVER AND DATABASE IS THIS? 2026-10-11.
--
-- READ-ONLY, ONE STATEMENT. Run only by 10_assess.sh, which connects through the
-- local Unix socket with default_transaction_read_only=on.
--
-- Deliberately references NO Odoo table, so it runs on ANY database. That is what
-- lets 10_assess.sh recognise a wrong database before querying anything inside it.
--
-- socket       inet_server_addr() is NULL only for a Unix-socket connection, which
--              can only reach a server on this same machine.
-- read_only    must be "on" - proves the session guard is in force.
-- odoo_tables  the three Odoo tables 10b reads must exist.
--
-- OUTPUT: key|value rows (psql -At -F '|').

SELECT key, value FROM (VALUES
    ('socket',         (inet_server_addr() IS NULL)::text),
    ('database',       current_database()::text),
    ('port',           current_setting('port')),
    ('data_directory', current_setting('data_directory')),
    ('read_only',      current_setting('transaction_read_only')),
    ('server_version', current_setting('server_version')),
    ('odoo_tables',    (to_regclass('public.ir_config_parameter') IS NOT NULL
                        AND to_regclass('public.ir_module_module') IS NOT NULL
                        AND to_regclass('public.account_move_line') IS NOT NULL)::text)
) AS f(key, value);
