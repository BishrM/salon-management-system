-- M3 tables: float, closings, immutable revisions, events, handovers, late-entry reviews,
-- Paytm transactions (Rev 6 §3.3, §3.4, §5, §7). All financial snapshots are insert-only (F1).

create function app.denom_total(p jsonb)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select coalesce(sum((k)::bigint * (v)::bigint), 0)::bigint from jsonb_each_text(coalesce(p, '{}')) as t(k, v)
$$;

-- Float movements (F2, F4, G1, G2, J4) ----------------------------------------------------------------
create table public.float_movements (
  id                       uuid primary key default gen_random_uuid(),
  outlet_id                uuid not null references public.outlets (id),
  type                     text not null check (type in ('initial_float', 'top_up', 'required_float_change')),
  effective_business_date  date not null,
  timing                   text check (timing in ('pre_opening', 'intraday')),
  amount                   bigint check (amount > 0 and amount % 100 = 0),
  new_required_float       bigint check (new_required_float >= 0 and new_required_float % 100 = 0),
  source                   text check (source in ('owner_funds', 'previous_take_home', 'other')),
  source_note              text,
  relates_to_revision_id   uuid,                     -- FK added below
  denominations            jsonb,
  authorised_by            uuid not null references public.profiles (id),
  recorded_by              uuid not null references public.profiles (id),
  recorded_at              timestamptz not null default now(),
  reason                   text not null check (length(btrim(reason)) > 0),
  reverses_movement_id     uuid unique references public.float_movements (id),
  confirmation             jsonb,
  constraint float_type_columns check (
    case type
      when 'required_float_change' then
        timing is null and amount is null and source is null and new_required_float is not null
      else
        timing is not null and amount is not null and source is not null and new_required_float is null
    end
  ),
  constraint float_initial_rules check (
    type <> 'initial_float' or (
      timing = 'pre_opening'
      and denominations is not null
      and amount = app.denom_total(denominations)
      and recorded_by = authorised_by
      and reverses_movement_id is null
      and confirmation is not null
      and confirmation ->> 'method' = 'single_action_retyped_total'
      and (confirmation ->> 'self_confirmed')::boolean
      and (confirmation ->> 'retyped_total')::bigint = amount
      and (confirmation ->> 'entered_by')::uuid = recorded_by
      and (confirmation ->> 'confirmed_by')::uuid = recorded_by
    )
  ),
  constraint float_other_note check (source is distinct from 'other' or length(btrim(coalesce(source_note, ''))) > 0)
);
-- G2: a second initialisation is impossible, including concurrent calls.
create unique index float_initial_uidx on public.float_movements (outlet_id) where type = 'initial_float';
create index float_movements_day_idx on public.float_movements (outlet_id, effective_business_date);
create trigger float_movements_immutable before update or delete on public.float_movements
  for each row execute function app.forbid_mutation();
create trigger float_movements_audit after insert on public.float_movements
  for each row execute function app.audit_row();

-- Closings ----------------------------------------------------------------------------------------------
create table public.daily_closings (
  id             uuid primary key default gen_random_uuid(),
  outlet_id      uuid not null references public.outlets (id),
  business_date  date not null,
  created_by     uuid not null references public.profiles (id),
  created_at     timestamptz not null default now(),
  unique (outlet_id, business_date)
);
create trigger daily_closings_immutable before update or delete on public.daily_closings
  for each row execute function app.forbid_mutation();
create trigger daily_closings_audit after insert on public.daily_closings
  for each row execute function app.audit_row();

create table public.closing_drafts (
  closing_id       uuid primary key references public.daily_closings (id),
  outlet_id        uuid not null references public.outlets (id),
  paytm_total      bigint check (paytm_total >= 0 and paytm_total % 100 = 0),
  paytm_upi        bigint check (paytm_upi >= 0 and paytm_upi % 100 = 0),
  paytm_card       bigint check (paytm_card >= 0 and paytm_card % 100 = 0),
  denominations    jsonb not null default '{}',    -- {"50000": 3, "10000": 12, ...} paise → count
  variance_reason  text check (variance_reason is null or length(variance_reason) <= 500),
  take_home_by     text check (take_home_by is null or length(take_home_by) <= 120),
  updated_by       uuid references public.profiles (id),
  updated_at       timestamptz not null default now()
);
create trigger closing_drafts_no_delete before delete on public.closing_drafts
  for each row execute function app.forbid_mutation();
create trigger closing_drafts_audit after insert or update on public.closing_drafts
  for each row execute function app.audit_row();

create table public.closing_revisions (
  id                                uuid primary key default gen_random_uuid(),
  closing_id                        uuid not null references public.daily_closings (id),
  outlet_id                         uuid not null references public.outlets (id),
  business_date                     date not null,
  revision_no                       integer not null check (revision_no >= 1),
  -- Inputs copied from the draft.
  paytm_total                       bigint not null check (paytm_total >= 0),
  paytm_upi                         bigint,
  paytm_card                        bigint,
  denominations                     jsonb not null,
  variance_reason                   text,
  take_home_by                      text,
  -- Float (G1).
  retained_float_carried            bigint not null,           -- R
  opening_float_source_revision_id  uuid references public.closing_revisions (id),
  initial_float_movement_id         uuid references public.float_movements (id),
  pre_opening_funding               bigint not null,           -- PF
  pre_opening_movement_ids          uuid[] not null default '{}',
  opening_float                     bigint not null,           -- O
  intraday_top_ups                  bigint not null,           -- I
  intraday_movement_ids             uuid[] not null default '{}',
  included_late_entry_ids           uuid[] not null default '{}',
  entries_snapshot                  jsonb not null,            -- [{id, kind, amount, staff_id, version}]
  -- Computed snapshot (§5).
  service_total                     bigint not null,           -- S
  commission_pool                   bigint not null,           -- C
  product_total                     bigint not null,           -- P
  product_cash                      bigint not null,
  product_paytm                     bigint not null,
  service_paytm                     bigint not null,
  cash_sales                        bigint not null,           -- CS
  expenses_total                    bigint not null,           -- E (drawer only, O2)
  expenses_outside_total            bigint not null,           -- informational
  zakat_total                       bigint not null,           -- Z
  food_cost                         bigint not null,           -- F
  food_commission_funded            bigint not null,           -- FC
  food_shop_funded                  bigint not null,           -- FX
  remaining_payable                 bigint not null,
  food_paid_drawer_today            bigint not null,
  food_paid_drawer_prior            bigint not null,           -- Fprior
  food_paid_drawer                  bigint not null,           -- Fd
  food_not_paid_drawer              bigint not null,           -- U
  food_payment_ids                  uuid[] not null default '{}',
  drawer_handover_total             bigint not null,           -- H
  drawer_handover_ids               uuid[] not null default '{}',
  commission_retained               bigint not null,           -- Rc
  net_cash                          bigint not null,           -- N (SRS formula)
  expected_drawer                   bigint not null,           -- ED
  counted_cash                      bigint not null check (counted_cash >= 0),  -- CC
  variance                          bigint not null,           -- V
  required_float                    bigint not null check (required_float >= 0), -- RF
  retained_float                    bigint not null,           -- AF
  float_shortfall                   bigint not null,           -- FS
  take_home                         bigint not null,           -- TH
  paytm_flags                       text[] not null default '{}',
  submitted_by                      uuid not null references public.profiles (id),
  submitted_at                      timestamptz not null default now(),
  unique (closing_id, revision_no),
  -- Rev 6 §3.3 / §5.3 invariants.
  constraint rev_commission check (commission_pool = (service_total / 10000) * 1000),
  constraint rev_opening check (opening_float = retained_float_carried + pre_opening_funding),
  constraint rev_float_source check (
    (opening_float_source_revision_id is null) <> (initial_float_movement_id is null)
  ),
  constraint rev_cash_sales check (cash_sales = service_total + product_total - paytm_total),
  constraint rev_product_split check (product_total = product_cash + product_paytm),
  constraint rev_service_paytm check (service_paytm = paytm_total - product_paytm),
  constraint rev_food_split check (
    food_commission_funded + food_shop_funded = food_cost
    and food_commission_funded between 0 and commission_pool and food_shop_funded >= 0
  ),
  constraint rev_payable check (remaining_payable = commission_pool - food_commission_funded),
  constraint rev_fd check (food_paid_drawer = food_paid_drawer_today + food_paid_drawer_prior),
  constraint rev_u check (food_not_paid_drawer = food_cost - food_paid_drawer_today),
  constraint rev_rc check (commission_retained = remaining_payable - drawer_handover_total),
  constraint rev_n check (
    net_cash = service_total - commission_pool + product_total - paytm_total - expenses_total - zakat_total
  ),
  constraint rev_ed check (
    expected_drawer = opening_float + intraday_top_ups + cash_sales - expenses_total - zakat_total
                      - food_paid_drawer - drawer_handover_total
  ),
  constraint rev_bridge check (
    expected_drawer = opening_float + intraday_top_ups + net_cash + commission_retained
                      + food_not_paid_drawer - food_paid_drawer_prior - food_shop_funded
  ),
  constraint rev_cc check (counted_cash = app.denom_total(denominations)),
  constraint rev_v check (variance = counted_cash - expected_drawer),
  constraint rev_variance_reason check (variance = 0 or length(btrim(coalesce(variance_reason, ''))) > 0),
  constraint rev_af check (
    retained_float = least(counted_cash, required_float)
    and float_shortfall = greatest(0, required_float - counted_cash)
    and take_home = greatest(0, counted_cash - required_float)
    and counted_cash = retained_float + take_home
  ),
  constraint rev_take_home_by check (take_home = 0 or length(btrim(coalesce(take_home_by, ''))) > 0)
);
create index closing_revisions_outlet_idx on public.closing_revisions (outlet_id, business_date);
create trigger closing_revisions_immutable before update or delete on public.closing_revisions
  for each row execute function app.forbid_mutation();
create trigger closing_revisions_audit after insert on public.closing_revisions
  for each row execute function app.audit_row();

alter table public.entries add constraint entries_late_revision_fk
  foreign key (late_against_revision_id) references public.closing_revisions (id);
alter table public.food_payments add constraint food_payments_late_revision_fk
  foreign key (late_against_revision_id) references public.closing_revisions (id);
alter table public.float_movements add constraint float_relates_revision_fk
  foreign key (relates_to_revision_id) references public.closing_revisions (id);

create table public.revision_denominations (
  revision_id   uuid not null references public.closing_revisions (id),
  outlet_id     uuid not null references public.outlets (id),
  denomination  bigint not null check (denomination > 0),
  qty           integer not null check (qty >= 0),
  subtotal      bigint not null,
  primary key (revision_id, denomination),
  constraint revision_denominations_subtotal check (subtotal = denomination * qty)
);
create trigger revision_denominations_immutable before update or delete on public.revision_denominations
  for each row execute function app.forbid_mutation();

create table public.revision_commission_allocations (
  revision_id    uuid not null references public.closing_revisions (id),
  outlet_id      uuid not null references public.outlets (id),
  staff_id       uuid not null references public.staff (id),
  staff_name     text not null,
  service_total  bigint not null check (service_total >= 0),
  exact_share    bigint not null,           -- S_i / 10 (exact, paise; entries are whole rupees)
  allocated      bigint not null check (allocated >= 0 and allocated % 1000 = 0),
  rounding_adj   bigint not null,
  primary key (revision_id, staff_id),
  constraint allocation_exact check (exact_share * 10 = service_total),
  constraint allocation_rounding check (rounding_adj = allocated - exact_share)   -- J3
);
create trigger revision_allocations_immutable before update or delete on public.revision_commission_allocations
  for each row execute function app.forbid_mutation();

create table public.closing_events (
  id           uuid primary key default gen_random_uuid(),
  closing_id   uuid not null references public.daily_closings (id),
  outlet_id    uuid not null references public.outlets (id),
  revision_id  uuid references public.closing_revisions (id),
  type         text not null check (type in (
                 'submitted', 'approved', 'rejected', 'reopened',
                 'review_flagged', 'review_acknowledged', 'food_excess_allocated')),
  actor        uuid not null references public.profiles (id),
  at           timestamptz not null default clock_timestamp(),
  server_seq   bigint not null default nextval('app.server_seq'),
  reason       text,
  payload      jsonb not null default '{}',
  constraint closing_events_reason check (
    type not in ('rejected', 'reopened', 'food_excess_allocated') or length(btrim(coalesce(reason, ''))) > 0
  )
);
create index closing_events_closing_idx on public.closing_events (closing_id, server_seq);
create trigger closing_events_immutable before update or delete on public.closing_events
  for each row execute function app.forbid_mutation();
create trigger closing_events_audit after insert on public.closing_events
  for each row execute function app.audit_row();

-- Commission handovers (G5, H1, J1) -------------------------------------------------------------------
create table public.commission_handovers (
  id                  uuid primary key default gen_random_uuid(),
  closing_id          uuid not null references public.daily_closings (id),
  outlet_id           uuid not null references public.outlets (id),
  revision_id         uuid references public.closing_revisions (id),   -- current revision at the time
  kind                text not null check (kind in ('handover', 'return', 'overpayment_accepted')),
  source              text check (source in ('drawer', 'outside_drawer')),
  amount              bigint not null check (amount > 0 and amount % 100 = 0),
  recipient_staff_id  uuid references public.staff (id),
  received_by         uuid references public.profiles (id),
  reason              text,
  at                  timestamptz not null default clock_timestamp(),
  recorded_by         uuid not null references public.profiles (id),
  constraint handover_kind_columns check (
    case kind
      when 'handover' then source is not null and recipient_staff_id is not null and received_by is null
      when 'return' then source is not null and received_by is not null and recipient_staff_id is null
                         and length(btrim(coalesce(reason, ''))) > 0
      when 'overpayment_accepted' then source is null and recipient_staff_id is null and received_by is null
                         and length(btrim(coalesce(reason, ''))) > 0
    end
  ),
  -- J1: drawer movements are only possible before the day's first revision.
  constraint handover_drawer_before_submit check (source is distinct from 'drawer' or revision_id is null)
);
create index commission_handovers_closing_idx on public.commission_handovers (closing_id);
create trigger commission_handovers_immutable before update or delete on public.commission_handovers
  for each row execute function app.forbid_mutation();
create trigger commission_handovers_audit after insert on public.commission_handovers
  for each row execute function app.audit_row();

-- Late-entry decisions (H3). Latest row per entry is effective; earlier ones are kept. ---------------
create table public.late_entry_reviews (
  id          uuid primary key default gen_random_uuid(),
  entry_kind  text not null check (entry_kind in ('entry', 'food_payment')),
  entry_id    uuid not null,
  closing_id  uuid not null references public.daily_closings (id),
  outlet_id   uuid not null references public.outlets (id),
  decision    text not null check (decision in ('include', 'exclude')),
  reason      text,
  decided_by  uuid not null references public.profiles (id),
  at          timestamptz not null default clock_timestamp(),
  server_seq  bigint not null default nextval('app.server_seq'),
  constraint late_review_reason check (decision <> 'exclude' or length(btrim(coalesce(reason, ''))) > 0)
);
create index late_entry_reviews_entry_idx on public.late_entry_reviews (entry_kind, entry_id, server_seq desc);
create trigger late_entry_reviews_immutable before update or delete on public.late_entry_reviews
  for each row execute function app.forbid_mutation();
create trigger late_entry_reviews_audit after insert on public.late_entry_reviews
  for each row execute function app.audit_row();

-- Paytm transactions (M7 CSV fallback, SRS §11). Insert-only; one row per Paytm reference. ----------
create table public.paytm_transactions (
  id             uuid primary key default gen_random_uuid(),
  outlet_id      uuid not null references public.outlets (id),
  txn_ref        text not null check (length(btrim(txn_ref)) between 1 and 100),
  txn_time       timestamptz not null,
  business_date  date not null,
  amount         bigint not null check (amount > 0),
  status         text not null check (status in ('success', 'pending', 'failed', 'refunded')),
  method         text not null default 'unknown' check (method in ('upi', 'card', 'unknown')),
  import_batch   uuid not null,
  source_name    text,
  imported_by    uuid not null references public.profiles (id),
  imported_at    timestamptz not null default now(),
  unique (outlet_id, txn_ref)
);
create index paytm_transactions_day_idx on public.paytm_transactions (outlet_id, business_date);
create trigger paytm_transactions_immutable before update or delete on public.paytm_transactions
  for each row execute function app.forbid_mutation();

-- Derived lifecycle (F1): latest of submitted/approved/rejected/reopened; no event = draft. ----------
create view public.closing_state with (security_invoker = true) as
select
  c.id as closing_id,
  c.outlet_id,
  c.business_date,
  coalesce(ev.type, 'draft') as state,
  ev.at as state_at,
  ev.actor as state_by,
  ev.reason as state_reason,
  rv.id as current_revision_id,
  rv.revision_no as current_revision_no
from public.daily_closings c
left join lateral (
  select e.type, e.at, e.actor, e.reason from public.closing_events e
  where e.closing_id = c.id and e.type in ('submitted', 'approved', 'rejected', 'reopened')
  order by e.server_seq desc limit 1
) ev on true
left join lateral (
  select r.id, r.revision_no from public.closing_revisions r
  where r.closing_id = c.id order by r.revision_no desc limit 1
) rv on true;

-- Reporting views with the Rev 6 / SRS table names (D-01). -------------------------------------------
create view public.service_sales with (security_invoker = true) as
  select * from public.entries where kind = 'service';
create view public.product_sales with (security_invoker = true) as
  select * from public.entries where kind = 'product';
create view public.expenses with (security_invoker = true) as
  select * from public.entries where kind = 'expense';
create view public.zakat_entries with (security_invoker = true) as
  select * from public.entries where kind = 'zakat';
create view public.food_deductions with (security_invoker = true) as
  select * from public.entries where kind = 'food';
