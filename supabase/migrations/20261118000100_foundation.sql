-- M1 foundation: helper schema, shared sequence, role enum, generic guard triggers, audit log.
-- Plan reference: Rev 6 §3 (insert-only rule, audit_logs), §4 (roles).

create extension if not exists btree_gist with schema extensions;

-- Helper schema. Not exposed through the Data API (config.toml [api].schemas), so nothing in it
-- is callable over REST. RLS policies call a few helpers from here, so authenticated needs USAGE.
create schema app;
revoke all on schema app from public;
grant usage on schema app to authenticated;

-- Global receipt order shared by audit rows now and by financial entries from M2 (Rev 6 §3.2).
create sequence app.server_seq;

create type public.app_role as enum ('owner', 'manager', 'head', 'counter');
comment on type public.app_role is
  'owner = owner; manager = owner''s son (SRS §5.2); head = head employee (acting head = head row with is_acting); counter = counter operator.';

-- Raises for every role, including SECURITY DEFINER functions (Rev 6 §3 "insert-only").
create function app.forbid_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '%.% does not allow %', tg_table_schema, tg_table_name, tg_op
    using errcode = 'P0001', hint = 'insert-only table';
end;
$$;

create function app.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Append-only audit log (Rev 6 §3.5).
create table public.audit_logs (
  id          bigint generated always as identity primary key,
  server_seq  bigint not null default nextval('app.server_seq'),
  outlet_id   uuid,
  table_name  text not null,
  row_id      uuid,
  op_id       uuid,
  action      text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data    jsonb,
  new_data    jsonb,
  reason      text,
  actor       uuid,
  db_role     text not null default current_user,
  at          timestamptz not null default now()
);
comment on column public.audit_logs.op_id is
  'Client/RPC operation id (idempotency key). Unique per (op_id, table_name, row_id); one op may touch several rows.';
comment on column public.audit_logs.actor is 'auth.uid() of the caller; NULL for migrations / service maintenance.';

create unique index audit_logs_op_row_uidx on public.audit_logs (op_id, table_name, row_id) where op_id is not null;
create index audit_logs_outlet_seq_idx on public.audit_logs (outlet_id, server_seq);
create index audit_logs_row_idx on public.audit_logs (table_name, row_id);

create trigger audit_logs_no_update_delete
  before update or delete on public.audit_logs
  for each row execute function app.forbid_mutation();
create trigger audit_logs_no_truncate
  before truncate on public.audit_logs
  for each statement execute function app.forbid_mutation();

-- Generic row audit. Reason and op id come from transaction-local settings set by RPCs:
--   perform set_config('app.reason', p_reason, true);
--   perform set_config('app.op_id', p_op_id::text, true);
create function app.audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old    jsonb;
  v_new    jsonb;
  v_row    uuid;
  v_outlet uuid;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;

  v_row := (coalesce(v_new, v_old) ->> 'id')::uuid;
  if tg_table_name = 'outlets' then
    v_outlet := v_row;
  else
    v_outlet := nullif(coalesce(v_new, v_old) ->> 'outlet_id', '')::uuid;
  end if;

  insert into public.audit_logs (outlet_id, table_name, row_id, op_id, action, old_data, new_data, reason, actor)
  values (
    v_outlet, tg_table_name, v_row,
    nullif(current_setting('app.op_id', true), '')::uuid,
    tg_op, v_old, v_new,
    nullif(current_setting('app.reason', true), ''),
    auth.uid()
  );
  return null;
end;
$$;
