-- Paytm CSV re-import: report rows whose amount or status differs from the earlier import.
-- Imported transactions stay immutable (they are a comparison record, not accounting input), but a
-- statement downloaded later can show a transaction as success/refunded that was pending/failed before.
-- Previously such rows were silently counted as "already imported"; now they are counted as `changed`
-- and listed so management can see the comparison is based on the earlier status.
create or replace function public.import_paytm_transactions(p_outlet uuid, p_rows jsonb, p_source_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch    uuid := gen_random_uuid();
  v_row      jsonb;
  v_inserted int := 0;
  v_dupes    int := 0;
  v_changed  text[] := '{}';
  v_n        int;
  v_amount   numeric;
  v_old      public.paytm_transactions;
begin
  perform app.require_permission(p_outlet, 'paytm.enter');
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 5000 then
    raise exception 'rows must be an array of at most 5000 transactions' using errcode = '22023';
  end if;
  for v_row in select value from jsonb_array_elements(p_rows) loop
    if coalesce(btrim(v_row ->> 'txn_ref'), '') = '' or (v_row ->> 'txn_time') is null then
      raise exception 'every row needs a transaction reference and time' using errcode = '22023';
    end if;
    v_amount := (v_row ->> 'amount')::numeric;
    if v_amount is null or v_amount <= 0 or v_amount <> trunc(v_amount) then
      raise exception 'amount for % must be positive paise', v_row ->> 'txn_ref' using errcode = '22023';
    end if;
    if coalesce(v_row ->> 'status', '') not in ('success', 'pending', 'failed', 'refunded') then
      raise exception 'status for % must be success, pending, failed or refunded', v_row ->> 'txn_ref'
        using errcode = '22023';
    end if;
    insert into public.paytm_transactions (outlet_id, txn_ref, txn_time, business_date, amount, status, method,
      import_batch, source_name, imported_by)
    values (p_outlet, btrim(v_row ->> 'txn_ref'), (v_row ->> 'txn_time')::timestamptz,
      app.business_date(p_outlet, (v_row ->> 'txn_time')::timestamptz), v_amount::bigint, v_row ->> 'status',
      coalesce(nullif(v_row ->> 'method', ''), 'unknown'), v_batch, left(p_source_name, 200), auth.uid())
    on conflict (outlet_id, txn_ref) do nothing;
    get diagnostics v_n = row_count;
    if v_n = 1 then
      v_inserted := v_inserted + 1;
    else
      select * into v_old from public.paytm_transactions
       where outlet_id = p_outlet and txn_ref = btrim(v_row ->> 'txn_ref');
      if v_old.amount <> v_amount::bigint or v_old.status <> v_row ->> 'status' then
        v_changed := v_changed || v_old.txn_ref;
      else
        v_dupes := v_dupes + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('batch', v_batch, 'inserted', v_inserted, 'duplicates', v_dupes,
    'changed', cardinality(v_changed), 'changed_refs', to_jsonb(v_changed[1:20]));
end;
$$;
