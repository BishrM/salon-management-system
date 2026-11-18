-- RLS, privileges and realtime for M2–M7 objects (Rev 6 §4). SELECT through RLS only; every write
-- goes through the SECURITY DEFINER RPC allow-list below.

alter table public.entries                          enable row level security;
alter table public.food_payments                    enable row level security;
alter table public.sync_ops                         enable row level security;
alter table public.float_movements                  enable row level security;
alter table public.daily_closings                   enable row level security;
alter table public.closing_drafts                   enable row level security;
alter table public.closing_revisions                enable row level security;
alter table public.revision_denominations           enable row level security;
alter table public.revision_commission_allocations  enable row level security;
alter table public.closing_events                   enable row level security;
alter table public.commission_handovers             enable row level security;
alter table public.late_entry_reviews               enable row level security;
alter table public.paytm_transactions               enable row level security;

create policy entries_select on public.entries for select to authenticated using (app.is_member(outlet_id));
create policy food_payments_select on public.food_payments for select to authenticated using (app.is_member(outlet_id));
create policy sync_ops_select on public.sync_ops for select to authenticated
  using (submitted_by = auth.uid() or app.has_permission(outlet_id, 'sync.manage'));
create policy float_movements_select on public.float_movements for select to authenticated using (app.is_member(outlet_id));
create policy daily_closings_select on public.daily_closings for select to authenticated using (app.is_member(outlet_id));
create policy closing_drafts_select on public.closing_drafts for select to authenticated using (app.is_member(outlet_id));
create policy closing_revisions_select on public.closing_revisions for select to authenticated using (app.is_member(outlet_id));
create policy revision_denominations_select on public.revision_denominations for select to authenticated using (app.is_member(outlet_id));
create policy revision_allocations_select on public.revision_commission_allocations for select to authenticated using (app.is_member(outlet_id));
create policy closing_events_select on public.closing_events for select to authenticated using (app.is_member(outlet_id));
create policy commission_handovers_select on public.commission_handovers for select to authenticated using (app.is_member(outlet_id));
create policy late_entry_reviews_select on public.late_entry_reviews for select to authenticated using (app.is_member(outlet_id));
create policy paytm_transactions_select on public.paytm_transactions for select to authenticated
  using (app.has_permission(outlet_id, 'paytm.enter'));

-- Table privileges: SELECT only (views are security_invoker, so RLS of the base table applies).
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant select on
  public.outlets, public.profiles, public.outlet_memberships, public.staff, public.staff_assignments,
  public.devices, public.audit_logs, public.product_catalog,
  public.entries, public.food_payments, public.sync_ops, public.float_movements, public.daily_closings,
  public.closing_drafts, public.closing_revisions, public.revision_denominations,
  public.revision_commission_allocations, public.closing_events, public.commission_handovers,
  public.late_entry_reviews, public.paytm_transactions,
  public.closing_state, public.service_sales, public.product_sales, public.expenses, public.zakat_entries,
  public.food_deductions
to authenticated;

-- Functions: nothing by default (per-schema default privileges cannot revoke PUBLIC, so revoke here).
revoke execute on all functions in schema app from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

-- Predicates evaluated by RLS policies as the caller.
grant execute on function
  app.my_valid_memberships(),
  app.valid_memberships_of(uuid),
  app.permission_matrix(),
  app.has_permission(uuid, text),
  app.is_member(uuid),
  app.is_owner_anywhere(),
  app.can_view_profile(uuid),
  app.can_view_staff(uuid)
to authenticated;

-- Client RPC allow-list.
grant execute on function
  public.my_permissions(uuid),
  public.server_time(),
  public.current_business_date(uuid),
  public.set_outlet_cutoff(uuid, time, text),
  public.set_outlet_denominations(uuid, integer[], text),
  public.set_offline_thresholds(uuid, integer, integer, integer, text),
  public.set_outlet_details(uuid, text, text, date, text),
  public.create_staff(uuid, text, date, uuid),
  public.assign_staff(uuid, uuid, date, text),
  public.assign_staff_temporary(uuid, uuid, date, date, text),
  public.end_staff_assignment(uuid, date, text),
  public.update_staff(uuid, text, boolean, text),
  public.upsert_product(uuid, uuid, text, bigint, boolean),
  public.add_membership(uuid, uuid, public.app_role, text),
  public.grant_acting_head(uuid, uuid, timestamptz, text, timestamptz),
  public.revoke_membership(uuid, text),
  public.sync_ops(uuid, uuid, text, jsonb),
  public.resolve_sync_issue(bigint, text),
  public.assign_business_date(text, uuid, date, text),
  public.day_summary(uuid, date),
  public.prepare_closing(uuid, date),
  public.update_draft(uuid, bigint, bigint, bigint, jsonb, text, text),
  public.allocate_food_excess(uuid, text),
  public.submit_closing(uuid),
  public.approve_closing(uuid, text[]),
  public.reject_closing(uuid, text),
  public.reopen_closing(uuid, text),
  public.acknowledge_review(uuid, text, text),
  public.review_late_entry(text, uuid, text, text, text),
  public.establish_initial_float(uuid, date, jsonb, bigint),
  public.record_top_up(uuid, date, text, bigint, text, text, text, uuid),
  public.change_required_float(uuid, date, bigint, text),
  public.reverse_float_movement(uuid, text),
  public.record_handover(uuid, uuid, bigint, text),
  public.record_commission_return(uuid, bigint, text, text),
  public.accept_commission_overpayment(uuid, bigint, text),
  public.import_paytm_transactions(uuid, jsonb, text)
to authenticated;

-- Live dashboard (Rev 6 §2): Realtime respects RLS.
alter publication supabase_realtime add table public.entries, public.closing_events;
