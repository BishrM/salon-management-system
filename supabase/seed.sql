-- LOCAL / STAGING ONLY. Never run against production (Rev 6 §10).
-- Test logins for local development; passwords are test values for this app only.
-- Each user's password is the part of the email before "@", followed by "-Pass-1"
-- (owner@salonops.test → owner-Pass-1). Demo staff and catalogue below; the initial float is left
-- for the owner to establish through Admin → Cash float, exactly as in production.

create function pg_temp.seed_user(p_id uuid, p_email text, p_name text, p_password text)
returns void
language plpgsql
as $$
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, reauthentication_token, phone_change, phone_change_token
  ) values (
    p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', p_name), now(), now(),
    '', '', '', '', '', '', '', ''
  );
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (
    gen_random_uuid(), p_id, p_id::text, 'email',
    jsonb_build_object('sub', p_id::text, 'email', p_email, 'email_verified', true),
    now(), now(), now()
  );
end;
$$;

select pg_temp.seed_user('11111111-1111-4111-8111-111111111101', 'owner@salonops.test',   'Owner (test)',          'owner-Pass-1');
select pg_temp.seed_user('11111111-1111-4111-8111-111111111102', 'manager@salonops.test', 'Owner''s son (test)',    'manager-Pass-1');
-- The outlet's one shared Shop/Staff login (used by every employee at the salon; DECISIONS D-28).
select pg_temp.seed_user('11111111-1111-4111-8111-111111111103', 'shop@salonops.test',    'HUDCO Shop/Staff (test)', 'shop-Pass-1');
select pg_temp.seed_user('11111111-1111-4111-8111-111111111105', 'outsider@salonops.test','Other outlet owner (test)','outsider-Pass-1');

do $$
declare
  v_main  uuid;
  v_other uuid;
begin
  v_main := app.bootstrap_outlet(
    'HUDCO Big Boss',
    '2, HUDCO Main Road, Jayalakshmipuram, Bannimantap A Layout, Bannimantap, Mysuru, Karnataka 570015, India',
    '11111111-1111-4111-8111-111111111101');
  -- Dev convenience only: production sets the cutoff in the setup checklist (B1/F5).
  update public.outlets set day_cutoff = '04:00' where id = v_main;

  insert into public.outlet_memberships (outlet_id, profile_id, role, granted_by, reason) values
    (v_main, '11111111-1111-4111-8111-111111111102', 'manager', '11111111-1111-4111-8111-111111111101', 'seed'),
    (v_main, '11111111-1111-4111-8111-111111111103', 'shop',    '11111111-1111-4111-8111-111111111101', 'seed');

  -- Demo employees (records only, no logins) and catalogue.
  insert into public.staff (id, full_name, profile_id) values
    ('5eed0000-0000-4000-8000-000000000001', 'Arun', null),
    ('5eed0000-0000-4000-8000-000000000002', 'Bhavya', null),
    ('5eed0000-0000-4000-8000-000000000003', 'Chandan', null),
    ('5eed0000-0000-4000-8000-000000000004', 'Divya', null);
  insert into public.staff_assignments (staff_id, outlet_id, start_date)
  select id, v_main, current_date - 60 from public.staff where id::text like '5eed0000-%';
  insert into public.product_catalog (outlet_id, name, default_price) values
    (v_main, 'Hair oil 100 ml', 25000), (v_main, 'Shampoo 200 ml', 35000), (v_main, 'Beard wax', 18000);

  -- Second outlet exists only to exercise cross-outlet isolation locally.
  v_other := app.bootstrap_outlet('Isolation Test Outlet', null, '11111111-1111-4111-8111-111111111105');
end;
$$;
