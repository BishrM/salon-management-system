-- Food-policy effective date as the salon-local BUSINESS date (D-31 amendment, 2026-11-23).
-- …001800 defaulted outlets.food_rule_v2_from to the India calendar date at the moment it ran. Between
-- midnight and the outlet's cutoff (e.g. 04:00) the calendar date is one day ahead of the business day,
-- which would leave the business day in progress on the old rule. This sets each existing outlet's
-- effective date to its own business date at apply time (app.business_date: outlet timezone + cutoff).
-- Outlets without a cutoff (setup incomplete, no trading yet) keep the calendar date.
-- The update is audited (outlets_audit) with the reason below, so each environment records its own date:
-- staging when this is applied there; production when production is set up (outlets created later get
-- their creation date from the column default and must be confirmed in the setup checklist).
do $$
begin
  perform app.set_audit_context('food policy effective date = business date when migration 001900 was applied');
  -- CASE guards the call: app.business_date raises for an outlet without a cutoff, and WHERE clauses
  -- are not evaluated in a guaranteed order.
  update public.outlets o
     set food_rule_v2_from = d.business_day
    from (select id, case when day_cutoff is not null then app.business_date(id, now()) end as business_day
            from public.outlets) d
   where d.id = o.id and d.business_day is not null and o.food_rule_v2_from is distinct from d.business_day;
end;
$$;
