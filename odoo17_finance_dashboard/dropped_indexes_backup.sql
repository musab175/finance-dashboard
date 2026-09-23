 CREATE INDEX idx_am_fd_company_type_state_date ON public.account_move USING btree (company_id, move_type, state, invoice_date) INCLUDE (payment_state, amount_residual, amount_untaxed_signed, partner_id, invoice_date_due) WHERE ((state)::text = 'posted'::text);
 CREATE INDEX idx_aml_fd_balance_covering ON public.account_move_line USING btree (company_id, date) INCLUDE (balance, account_id) WHERE ((parent_state)::text = 'posted'::text);
 CREATE INDEX idx_aml_fd_balance_by_account ON public.account_move_line USING btree (company_id, account_id, date) INCLUDE (balance) WHERE ((parent_state)::text = 'posted'::text);

 CREATE STATISTICS stx_account_move_company_type_state_date ON (see pg_statistic_ext) 
 CREATE STATISTICS stx_account_move_company_type_state_mcv ON (see pg_statistic_ext) 

 CREATE STATISTICS stx_account_move_company_type_state_date (dependencies) ON company_id, state, move_type, invoice_date FROM account_move;
 CREATE STATISTICS stx_account_move_company_type_state_mcv (mcv) ON company_id, state, move_type, invoice_date FROM account_move;

