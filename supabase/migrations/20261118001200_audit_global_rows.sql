-- Staging acceptance S12 (2026-11-19) found a cross-outlet leak: audit rows of the global tables
-- `staff` and `profiles` carry no outlet_id, and the old policy let ANY owner read every such row
-- (an owner of outlet B saw outlet A's staff and user names and their audit history).
-- Now a row without an outlet is visible only to someone holding audit.read in an outlet the staff
-- member is assigned to, or that the profile is a member of. audit.read is owner-only, so other roles
-- still read no audit rows at all (O16). Rows of any other outlet-less table are hidden.

create function app.can_read_global_audit(p_table text, p_row uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case p_table
    when 'staff' then exists (
      select 1 from public.staff_assignments a
      where a.staff_id = p_row and app.has_permission(a.outlet_id, 'audit.read'))
    when 'profiles' then exists (
      select 1 from public.outlet_memberships m
      where m.profile_id = p_row and app.has_permission(m.outlet_id, 'audit.read'))
    else false
  end
$$;

revoke execute on function app.can_read_global_audit(text, uuid) from public, anon;
grant execute on function app.can_read_global_audit(text, uuid) to authenticated;

drop policy audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    (outlet_id is not null and app.has_permission(outlet_id, 'audit.read'))
    or (outlet_id is null and app.can_read_global_audit(table_name, row_id))
  );
