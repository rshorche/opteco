-- ============================================================================
-- Opteco — Initial Schema Migration
-- PostgreSQL / Supabase
-- ============================================================================
-- این اسکریپت هستهٔ Strategy Lifecycle + Rule Profile + Suggestion +
-- Symbol Universe + Alert + Subscription + Performance را می‌سازد.
--
-- نکات کلی:
--   - از gen_random_uuid() استفاده شده (نیازمند extension pgcrypto که در
--     Supabase به‌طور پیش‌فرض فعال است).
--   - جدول users یک پروفایل عمومی است که به auth.users (مدیریت‌شده توسط
--     Supabase Auth) وصل می‌شود؛ Supabase Auth خودش را نمی‌سازیم.
--   - RLS Policyهای نمونه در انتهای فایل آمده‌اند (Pattern، نه پوشش کامل هر
--     جدول) — قبل از Production باید برای هر جدول کامل شوند.
-- ============================================================================

create extension if not exists pgcrypto;

-- ============================================================================
-- 0. USERS (پروفایل عمومی روی auth.users)
-- ============================================================================

create table public.users (
    id                  uuid primary key references auth.users(id) on delete cascade,
    display_name        text,
    role                 text not null default 'USER' check (role in ('USER','ADMIN')),
    created_at            timestamptz not null default now(),
    updated_at              timestamptz not null default now()
);

-- ============================================================================
-- 1. SUBSCRIPTION DOMAIN
-- ============================================================================

create table public.subscription_plans (
    id                    uuid primary key default gen_random_uuid(),
    code                    text unique not null,
    display_name              text not null,
    features                    jsonb not null default '{}'::jsonb,
    price_amount                  numeric,
    billing_period_days              int,
    is_active                          boolean not null default true,
    created_at                            timestamptz not null default now()
);

create table public.trial_settings (
    id                    uuid primary key default gen_random_uuid(),
    plan_id                 uuid references public.subscription_plans(id),
    trial_duration_days       int not null,
    is_active                    boolean not null default true,
    updated_by                     uuid references public.users(id),
    updated_at                        timestamptz not null default now()
);

create table public.subscriptions (
    id                    uuid primary key default gen_random_uuid(),
    user_id                 uuid not null references public.users(id),
    plan_id                   uuid not null references public.subscription_plans(id),
    status                      text not null check (status in ('TRIALING','ACTIVE','EXPIRED','CANCELED')),
    trial_ends_at                  timestamptz,
    current_period_start              timestamptz,
    current_period_end                  timestamptz,
    created_at                             timestamptz not null default now(),
    updated_at                                timestamptz not null default now()
);

create index idx_subscriptions_user_status on public.subscriptions (user_id, status);

-- ============================================================================
-- 2. SYMBOL UNIVERSE DOMAIN
-- ============================================================================

create table public.symbols (
    id                    uuid primary key default gen_random_uuid(),
    symbol_code             text unique not null,
    display_name              text not null,
    status                       text not null default 'DISABLED' check (status in ('ACTIVE','DISABLED')),
    disable_reason                  text,
    admin_note                         text,
    last_reviewed_at                      timestamptz,
    last_reviewed_by                         uuid references public.users(id),
    created_at                                  timestamptz not null default now()
);

create index idx_symbols_status on public.symbols (status);

create table public.symbol_liquidity_snapshots (
    id                    uuid primary key default gen_random_uuid(),
    symbol_id               uuid not null references public.symbols(id) on delete cascade,
    snapshot_date              date not null,
    volume                        numeric,
    value_traded                     numeric,
    order_book_depth_score              numeric,
    source                                  text not null default 'MARKET_API',
    created_at                                 timestamptz not null default now()
);

create index idx_liquidity_symbol_date on public.symbol_liquidity_snapshots (symbol_id, snapshot_date);

-- ============================================================================
-- 3. STRATEGY CATALOG & RULE PROFILE DOMAIN
-- ============================================================================

create table public.strategy_definitions (
    id                    uuid primary key default gen_random_uuid(),
    code                    text unique not null,               -- 'covered_call','call_spread','collar', ...
    display_name_fa           text not null,
    display_name_en              text not null,
    module_ref                      text not null,
    is_active                          boolean not null default true,
    created_at                            timestamptz not null default now()
);

create table public.strategy_leg_roles (
    id                    uuid primary key default gen_random_uuid(),
    code                    text unique not null,               -- 'COVERED_UNDERLYING','SHORT_CALL', ...
    display_name_fa           text not null,
    applicable_instrument_type   text not null check (applicable_instrument_type in ('STOCK','OPTION','ANY')),
    description                     text
);

create table public.strategy_rule_profiles (
    id                    uuid primary key default gen_random_uuid(),
    strategy_definition_id  uuid not null references public.strategy_definitions(id),
    code                       text unique not null,
    display_name                 text not null,
    version                         int not null default 1,
    is_active                         boolean not null default true,
    is_default                           boolean not null default false,
    parameters                              jsonb not null default '{}'::jsonb,
    created_by                                 uuid references public.users(id),
    created_at                                    timestamptz not null default now()
);

create unique index uq_default_profile_per_definition
    on public.strategy_rule_profiles (strategy_definition_id)
    where is_default = true;

create table public.strategy_rule_definitions (
    id                    uuid primary key default gen_random_uuid(),
    rule_profile_id         uuid not null references public.strategy_rule_profiles(id) on delete cascade,
    rule_code                  text not null,
    scenario_category             text not null check (scenario_category in
                                      ('NEUTRAL','MODERATE_RISE','DECLINE','SHARP_RISE','SHARP_DECLINE','PREMIUM_EROSION')),
    condition_expression             jsonb not null,
    recommended_action                  text not null check (recommended_action in
                                      ('HOLD','OFFSET','ROLL','ROLL_UP','ROLL_DOWN','STRATEGY_TYPE_CHANGE','ACCEPT_EXERCISE')),
    alternative_actions                     jsonb,
    priority                                   int not null default 100,
    is_active                                     boolean not null default true,
    created_at                                       timestamptz not null default now(),

    unique (rule_profile_id, rule_code)
);

-- ============================================================================
-- 4. SUGGESTION ENGINE DOMAIN
-- ============================================================================

create table public.suggestion_risk_tiers (
    id                    uuid primary key default gen_random_uuid(),
    code                    text unique not null,               -- 'LOW','MEDIUM','HIGH', قابل افزودن سطح جدید
    display_name              text not null,
    sort_order                   int not null,
    is_active                       boolean not null default true
);

create table public.suggestion_batches (
    id                    uuid primary key default gen_random_uuid(),
    strategy_definition_id  uuid not null references public.strategy_definitions(id),
    rule_profile_id            uuid not null references public.strategy_rule_profiles(id),
    generated_at                  timestamptz not null default now(),
    status                           text not null default 'COMPLETED' check (status in ('COMPLETED','FAILED'))
);

create table public.suggestions (
    id                    uuid primary key default gen_random_uuid(),
    batch_id                 uuid not null references public.suggestion_batches(id) on delete cascade,
    symbol_id                   uuid not null references public.symbols(id),
    risk_tier_id                   uuid not null references public.suggestion_risk_tiers(id),
    candidate_instrument               jsonb not null,          -- {option_symbol, strike, expiry, option_type, contract_size}
    computed_metrics                       jsonb not null,      -- {break_even, max_profit, max_loss, monthly_yield, safety_margin, premium}
    market_data_snapshot                       jsonb not null,  -- {spot_price, bid, ask, volume, value_traded, captured_at}
    rank                                           int not null check (rank between 1 and 10),
    status                                            text not null default 'ACTIVE' check (status in ('ACTIVE','EXPIRED','SUPERSEDED')),
    generated_at                                         timestamptz not null default now(),
    expires_at                                              timestamptz not null
);

create index idx_suggestions_batch on public.suggestions (batch_id);
create index idx_suggestions_status on public.suggestions (status, expires_at);
create unique index uq_rank_per_batch_tier on public.suggestions (batch_id, risk_tier_id, rank);

-- ============================================================================
-- 5. STRATEGY LIFECYCLE CORE DOMAIN
-- ============================================================================

create table public.strategy_positions (
    id                    uuid primary key default gen_random_uuid(),
    user_id                 uuid not null references public.users(id),
    instrument_type            text not null check (instrument_type in ('STOCK','OPTION')),
    underlying_symbol             text not null,
    option_type                      text check (option_type in ('CALL','PUT')),
    strike_price                        numeric,
    expiry_date                            date,
    option_symbol                             text,
    contract_size                                numeric,
    direction                                       text not null check (direction in ('LONG','SHORT')),
    quantity                                           numeric not null check (quantity > 0),   -- Cache، منبع حقیقت = position_executions
    entry_price                                           numeric not null,                      -- Cache (میانگین وزنی)
    entry_date                                               timestamptz not null,
    status                                                      text not null default 'OPEN' check (status in ('OPEN','CLOSED')),
    close_reason                                                   text check (close_reason in ('BOUGHT_BACK','EXERCISED','EXPIRED','SOLD','TRANSFERRED')),
    close_price                                                       numeric,
    close_date                                                           timestamptz,
    created_at                                                              timestamptz not null default now(),
    updated_at                                                                 timestamptz not null default now(),

    check (instrument_type <> 'OPTION' or (option_type is not null and strike_price is not null
           and expiry_date is not null and option_symbol is not null)),
    check (status <> 'CLOSED' or (close_reason is not null and close_price is not null and close_date is not null)),
    check (status <> 'OPEN' or (close_reason is null and close_price is null and close_date is null))
);

create index idx_positions_user_status on public.strategy_positions (user_id, status);
create index idx_positions_symbol on public.strategy_positions (underlying_symbol);

create table public.position_executions (
    id                    uuid primary key default gen_random_uuid(),
    position_id              uuid not null references public.strategy_positions(id) on delete cascade,
    execution_type              text not null check (execution_type in ('OPEN','INCREASE','DECREASE','CLOSE')),
    quantity                       numeric not null check (quantity > 0),
    price                             numeric not null,
    executed_at                          timestamptz not null,
    close_reason                            text check (close_reason in ('BOUGHT_BACK','EXERCISED','EXPIRED','SOLD','TRANSFERRED')),
    related_transition_id                      uuid,   -- FK به strategy_transitions، بعد از تعریف آن جدول اضافه می‌شود
    notes                                          text,
    created_at                                       timestamptz not null default now(),

    check (execution_type <> 'CLOSE' or close_reason is not null),
    check (execution_type = 'CLOSE' or close_reason is null)
);

create index idx_executions_position on public.position_executions (position_id, executed_at);

create table public.strategy_instances (
    id                    uuid primary key default gen_random_uuid(),
    user_id                 uuid not null references public.users(id),
    status                     text not null default 'ACTIVE' check (status in ('ACTIVE','CLOSED')),
    underlying_symbol             text not null,
    started_at                       timestamptz not null default now(),
    closed_at                           timestamptz,
    created_at                             timestamptz not null default now(),
    updated_at                                timestamptz not null default now(),

    check (status <> 'CLOSED' or closed_at is not null),
    check (status <> 'ACTIVE' or closed_at is null)
);

create index idx_instances_user_status on public.strategy_instances (user_id, status);

create table public.strategy_cycles (
    id                    uuid primary key default gen_random_uuid(),
    strategy_instance_id     uuid not null references public.strategy_instances(id) on delete cascade,
    strategy_definition_id      uuid not null references public.strategy_definitions(id),
    status                          text not null default 'OPEN' check (status in ('OPEN','CLOSED')),
    origin_type                        text not null check (origin_type in ('INITIAL_ENTRY','TRANSITION')),
    origin_transition_id                  uuid,   -- FK بعد از تعریف strategy_transitions اضافه می‌شود
    entry_source                              text not null check (entry_source in ('SUGGESTED','MANUAL')),
    entry_suggestion_id                          uuid references public.suggestions(id),
    opened_at                                       timestamptz not null default now(),
    closed_at                                          timestamptz,
    created_at                                            timestamptz not null default now(),
    updated_at                                               timestamptz not null default now(),

    check (origin_type <> 'INITIAL_ENTRY' or origin_transition_id is null),
    check (origin_type <> 'TRANSITION' or origin_transition_id is not null),
    check (origin_type <> 'TRANSITION' or (entry_source = 'MANUAL' and entry_suggestion_id is null)),
    check (entry_source <> 'SUGGESTED' or entry_suggestion_id is not null),
    check (entry_source <> 'MANUAL' or entry_suggestion_id is null),
    check (status <> 'CLOSED' or closed_at is not null),
    check (status <> 'OPEN' or closed_at is null)
);

create index idx_cycles_instance on public.strategy_cycles (strategy_instance_id);
create index idx_cycles_status on public.strategy_cycles (status);

-- Fix 4: هر Instance حداکثر یک Cycle با origin_type=INITIAL_ENTRY می‌تواند داشته باشد
-- (تمام Cycleهای بعدی باید حتماً از یک Transition بیایند، طبق قانون قطعی Lifecycle)
create unique index uq_one_initial_entry_per_instance
    on public.strategy_cycles (strategy_instance_id)
    where origin_type = 'INITIAL_ENTRY';

create table public.strategy_transitions (
    id                    uuid primary key default gen_random_uuid(),
    strategy_instance_id     uuid not null references public.strategy_instances(id) on delete cascade,
    from_cycle_id                uuid not null references public.strategy_cycles(id),
    to_cycle_id                     uuid references public.strategy_cycles(id),   -- ★ null = Transition پایانی
    transition_type                    text not null check (transition_type in
                                          ('ROLL','OFFSET','STRATEGY_TYPE_CHANGE','EXERCISE','EXPIRE','PARTIAL_CLOSE','FINAL_CLOSE')),
    reason                                 jsonb,     -- {rule_profile_id, rule_code, triggered_condition, note}
    triggered_by                              text not null check (triggered_by in ('SYSTEM_RECOMMENDATION','USER_MANUAL')),
    user_confirmed                               boolean not null default true,
    execution_status                                text not null default 'RECORDED' check (execution_status in ('RECORDED')),
    notes                                              text,
    created_at                                            timestamptz not null default now(),

    check (from_cycle_id <> to_cycle_id)
);

create index idx_transitions_instance on public.strategy_transitions (strategy_instance_id);
create index idx_transitions_from_cycle on public.strategy_transitions (from_cycle_id);
create index idx_transitions_to_cycle on public.strategy_transitions (to_cycle_id);

-- تکمیل FKهای معلق (وابستگی چرخه‌ای بین cycles/transitions/executions)
alter table public.strategy_cycles
    add constraint fk_cycles_origin_transition
    foreign key (origin_transition_id) references public.strategy_transitions(id);

alter table public.position_executions
    add constraint fk_executions_transition
    foreign key (related_transition_id) references public.strategy_transitions(id);

-- ----------------------------------------------------------------------------
-- Fix 3: position_executions به‌عنوان Source of Truth
--
-- strategy_positions.quantity/entry_price/status/close_* از این پس فقط
-- Cache مشتق‌شده از position_executions هستند و هرگز مستقیماً توسط
-- Application نوشته نمی‌شوند؛ فقط از طریق INSERT روی position_executions
-- به‌روزرسانی می‌شوند. این Trigger اتمیک است (قفل ردیف با FOR UPDATE) و
-- جلوی DECREASE/CLOSE بیش از مقدار باز موجود، و جلوی افزودن Execution به
-- Position بسته‌شده را می‌گیرد.
-- ----------------------------------------------------------------------------

create or replace function public.fn_apply_position_execution()
returns trigger
language plpgsql
as $$
declare
    v_position          public.strategy_positions%rowtype;
    v_current_qty        numeric;
    v_new_qty              numeric;
    v_new_avg_price          numeric;
    v_prior_execution_count    int;
begin
    -- قفل ردیف Position برای جلوگیری از Race Condition بین دو Execution هم‌زمان
    select * into v_position
        from public.strategy_positions
        where id = new.position_id
        for update;

    if not found then
        raise exception 'strategy_positions % not found', new.position_id;
    end if;

    if v_position.status = 'CLOSED' then
        raise exception 'Position % is already CLOSED; no further executions allowed', new.position_id;
    end if;

    select count(*) into v_prior_execution_count
        from public.position_executions
        where position_id = new.position_id
          and id <> new.id;

    v_current_qty := v_position.quantity;

    if new.execution_type = 'OPEN' then
        if v_prior_execution_count > 0 then
            raise exception 'OPEN execution must be the first execution for position % (% prior executions found)',
                new.position_id, v_prior_execution_count;
        end if;
        v_new_qty := new.quantity;
        v_new_avg_price := new.price;

    elsif new.execution_type = 'INCREASE' then
        if v_prior_execution_count = 0 then
            raise exception 'INCREASE cannot be the first execution for position %; use OPEN', new.position_id;
        end if;
        v_new_qty := v_current_qty + new.quantity;
        v_new_avg_price := ((v_current_qty * v_position.entry_price) + (new.quantity * new.price)) / v_new_qty;

    elsif new.execution_type in ('DECREASE', 'CLOSE') then
        if v_prior_execution_count = 0 then
            raise exception '% cannot be the first execution for position %; position has no open quantity yet',
                new.execution_type, new.position_id;
        end if;

        if new.quantity > v_current_qty then
            raise exception 'Cannot % quantity % — exceeds open quantity % for position %',
                new.execution_type, new.quantity, v_current_qty, new.position_id;
        end if;

        v_new_qty := v_current_qty - new.quantity;
        v_new_avg_price := v_position.entry_price;  -- میانگین خرید با کاهش/بستن تغییر نمی‌کند

        if new.execution_type = 'CLOSE' and v_new_qty <> 0 then
            raise exception 'CLOSE must bring position quantity to exactly zero (remaining % ) for position %; use DECREASE for a partial reduction',
                v_new_qty, new.position_id;
        end if;

        if new.execution_type = 'DECREASE' and v_new_qty = 0 then
            raise exception 'DECREASE would bring quantity to zero for position %; use CLOSE instead', new.position_id;
        end if;
    end if;

    update public.strategy_positions
        set quantity     = case when v_new_qty = 0 then v_current_qty else v_new_qty end,
                                 -- در بستن نهایی، quantity آخرین مقدار بازِ بسته‌شده را نگه می‌دارد (نه صفر)
                                 -- چون strategy_positions.quantity یک CHECK (quantity > 0) دارد
            entry_price     = v_new_avg_price,
            status             = case when v_new_qty = 0 then 'CLOSED' else 'OPEN' end,
            close_reason         = case when v_new_qty = 0 then new.close_reason else null end,
            close_price            = case when v_new_qty = 0 then new.price else null end,
            close_date                = case when v_new_qty = 0 then new.executed_at else null end,
            updated_at                  = now()
        where id = new.position_id;

    return new;
end;
$$;

create trigger trg_apply_position_execution
    after insert on public.position_executions
    for each row
    execute function public.fn_apply_position_execution();

-- Ledger تغییرناپذیر است: Update/Delete روی position_executions مجاز نیست؛
-- اصلاح اشتباه فقط با ثبت یک Execution جبرانی جدید انجام می‌شود (Audit Trail کامل).
revoke update, delete on public.position_executions from authenticated;

create table public.strategy_transition_actions (
    id                    uuid primary key default gen_random_uuid(),
    transition_id            uuid not null references public.strategy_transitions(id) on delete cascade,
    position_id                  uuid not null references public.strategy_positions(id),
    action                          text not null check (action in ('CLOSED','CARRIED','OPENED','RELEASED','MODIFIED')),
    role_before_id                     uuid references public.strategy_leg_roles(id),
    role_after_id                          uuid references public.strategy_leg_roles(id),
    detail                                     jsonb,
    created_at                                    timestamptz not null default now(),

    check (action <> 'CLOSED' or role_after_id is null),
    check (action <> 'OPENED' or role_before_id is null),
    check (action not in ('CARRIED','MODIFIED') or role_before_id is not null)
);

create index idx_transition_actions_transition on public.strategy_transition_actions (transition_id);
create index idx_transition_actions_position on public.strategy_transition_actions (position_id);

create table public.strategy_legs (
    id                    uuid primary key default gen_random_uuid(),
    strategy_cycle_id        uuid not null references public.strategy_cycles(id) on delete cascade,
    position_id                  uuid not null references public.strategy_positions(id),
    role_id                          uuid not null references public.strategy_leg_roles(id),
    attached_at                          timestamptz not null default now(),
    detached_at                              timestamptz,
    created_at                                  timestamptz not null default now()
);

create unique index uq_position_open_leg
    on public.strategy_legs (position_id)
    where detached_at is null;

create table public.collateral_snapshots (
    id                    uuid primary key default gen_random_uuid(),
    position_id              uuid not null references public.strategy_positions(id) on delete cascade,
    transition_id                uuid references public.strategy_transitions(id),
    margin_required                  numeric,     -- [NEEDS OFFICIAL VERIFICATION]، فعلاً nullable
    coverage_type                        text not null check (coverage_type in ('COVERED_BY_STOCK','COVERED_BY_LONG_OPTION','NAKED')),
    coverage_source_position_id             uuid references public.strategy_positions(id),
    calculated_at                               timestamptz not null default now(),
    created_at                                     timestamptz not null default now(),

    check (coverage_type = 'NAKED' or coverage_source_position_id is not null),
    check (coverage_type <> 'NAKED' or coverage_source_position_id is null)
);

create index idx_collateral_position on public.collateral_snapshots (position_id);

create table public.strategy_events (
    id                    uuid primary key default gen_random_uuid(),
    strategy_instance_id     uuid not null references public.strategy_instances(id) on delete cascade,
    event_type                  text not null check (event_type in
                                   ('INSTANCE_STARTED','CYCLE_OPENED','CYCLE_CLOSED','TRANSITION_RECORDED','INSTANCE_CLOSED','ALERT_TRIGGERED')),
    ref_table                      text,
    ref_id                            uuid,
    occurred_at                          timestamptz not null default now(),
    created_at                              timestamptz not null default now()
);

create index idx_events_instance_time on public.strategy_events (strategy_instance_id, occurred_at);

-- ============================================================================
-- 6. ALERT DOMAIN
-- ============================================================================

create table public.alert_rule_definitions (
    id                    uuid primary key default gen_random_uuid(),
    strategy_definition_id  uuid not null references public.strategy_definitions(id),
    rule_profile_id             uuid not null references public.strategy_rule_profiles(id),
    event_code                     text not null,
    condition_expression              jsonb not null,
    severity                             text not null check (severity in ('INFO','WARNING','ACTION_REQUIRED')),
    linked_rule_code                        text,
    cooldown_minutes                           int not null default 720,
    is_active                                     boolean not null default true,

    unique (rule_profile_id, event_code)
);

create table public.alerts (
    id                    uuid primary key default gen_random_uuid(),
    user_id                 uuid not null references public.users(id),
    strategy_instance_id       uuid not null references public.strategy_instances(id),
    strategy_cycle_id             uuid references public.strategy_cycles(id),
    alert_rule_definition_id         uuid not null references public.alert_rule_definitions(id),
    status_snapshot                     jsonb not null,
    reason                                  text not null,
    key_info                                  jsonb not null,
    recommended_action                           text,   -- nullable: بعضی Alertها صرفاً اطلاع‌رسانی‌اند (مثل NEAR_EXPIRY) و اقدام اجباری ندارند
    alternative_actions                             jsonb,
    channel                                            text not null check (channel in ('TELEGRAM','SMS')),
    delivery_status                                       text not null default 'PENDING' check (delivery_status in ('PENDING','SENT','FAILED')),
    sent_at                                                  timestamptz,
    created_at                                                  timestamptz not null default now()
);

create index idx_alerts_user on public.alerts (user_id, created_at);
create index idx_alerts_dedup_lookup on public.alerts (strategy_cycle_id, alert_rule_definition_id, created_at);

create table public.telegram_links (
    id                    uuid primary key default gen_random_uuid(),
    user_id                 uuid not null references public.users(id),
    telegram_chat_id           text,
    link_token                    text unique not null,
    status                           text not null default 'PENDING' check (status in ('PENDING','LINKED','REVOKED')),
    linked_at                           timestamptz,
    created_at                             timestamptz not null default now()
);

create unique index uq_active_link_per_user on public.telegram_links (user_id) where status = 'LINKED';

-- ============================================================================
-- 7. PERFORMANCE DOMAIN
-- ============================================================================

create table public.performance_snapshots (
    id                    uuid primary key default gen_random_uuid(),
    strategy_instance_id     uuid not null references public.strategy_instances(id) on delete cascade,
    snapshot_date                date not null,
    cumulative_realized_pnl         numeric not null,
    cumulative_premium_income          numeric not null,
    unrealized_pnl                        numeric,
    share_quantity                           numeric not null,
    average_cost_basis                          numeric,
    cycle_count                                    int not null,
    offset_count                                      int not null,
    roll_count                                           int not null,
    created_at                                              timestamptz not null default now(),

    unique (strategy_instance_id, snapshot_date)
);

-- ============================================================================
-- ROW LEVEL SECURITY — پوشش کامل (Fix 5)
-- ============================================================================

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.users u where u.id = auth.uid() and u.role = 'ADMIN'
    );
$$;

-- ---- users --------------------------------------------------------------
alter table public.users enable row level security;
create policy "select_own_or_admin" on public.users for select
    using (id = auth.uid() or public.is_admin());
create policy "update_own" on public.users for update
    using (id = auth.uid());

-- ---- User-owned: strategy_positions --------------------------------------
alter table public.strategy_positions enable row level security;
create policy "select_own" on public.strategy_positions for select
    using (user_id = auth.uid());
create policy "insert_own" on public.strategy_positions for insert
    with check (user_id = auth.uid());
create policy "update_own" on public.strategy_positions for update
    using (user_id = auth.uid());
-- بدون Policy برای delete: Positionها هرگز حذف فیزیکی نمی‌شوند.

-- ---- User-owned: position_executions (via strategy_positions) -----------
alter table public.position_executions enable row level security;
create policy "select_own" on public.position_executions for select
    using (exists (
        select 1 from public.strategy_positions p
        where p.id = position_executions.position_id and p.user_id = auth.uid()
    ));
create policy "insert_own" on public.position_executions for insert
    with check (exists (
        select 1 from public.strategy_positions p
        where p.id = position_executions.position_id and p.user_id = auth.uid()
    ));
-- بدون Policy برای update/delete: Ledger تغییرناپذیر است (همچنین در سطح
-- GRANT هم قبلاً محدود شد).

-- ---- User-owned: strategy_instances ---------------------------------------
alter table public.strategy_instances enable row level security;
create policy "select_own" on public.strategy_instances for select
    using (user_id = auth.uid());
create policy "insert_own" on public.strategy_instances for insert
    with check (user_id = auth.uid());
create policy "update_own" on public.strategy_instances for update
    using (user_id = auth.uid());

-- ---- User-owned: strategy_cycles (via strategy_instances) -----------------
alter table public.strategy_cycles enable row level security;
create policy "select_own" on public.strategy_cycles for select
    using (exists (
        select 1 from public.strategy_instances i
        where i.id = strategy_cycles.strategy_instance_id and i.user_id = auth.uid()
    ));
create policy "insert_own" on public.strategy_cycles for insert
    with check (exists (
        select 1 from public.strategy_instances i
        where i.id = strategy_cycles.strategy_instance_id and i.user_id = auth.uid()
    ));
create policy "update_own" on public.strategy_cycles for update
    using (exists (
        select 1 from public.strategy_instances i
        where i.id = strategy_cycles.strategy_instance_id and i.user_id = auth.uid()
    ));

-- ---- User-owned: strategy_transitions (direct strategy_instance_id) -------
alter table public.strategy_transitions enable row level security;
create policy "select_own" on public.strategy_transitions for select
    using (exists (
        select 1 from public.strategy_instances i
        where i.id = strategy_transitions.strategy_instance_id and i.user_id = auth.uid()
    ));
create policy "insert_own" on public.strategy_transitions for insert
    with check (exists (
        select 1 from public.strategy_instances i
        where i.id = strategy_transitions.strategy_instance_id and i.user_id = auth.uid()
    ));
create policy "update_own" on public.strategy_transitions for update
    using (exists (
        select 1 from public.strategy_instances i
        where i.id = strategy_transitions.strategy_instance_id and i.user_id = auth.uid()
    ));

-- ---- User-owned: strategy_transition_actions (via transition→instance) ----
alter table public.strategy_transition_actions enable row level security;
create policy "select_own" on public.strategy_transition_actions for select
    using (exists (
        select 1 from public.strategy_transitions t
        join public.strategy_instances i on i.id = t.strategy_instance_id
        where t.id = strategy_transition_actions.transition_id and i.user_id = auth.uid()
    ));
create policy "insert_own" on public.strategy_transition_actions for insert
    with check (exists (
        select 1 from public.strategy_transitions t
        join public.strategy_instances i on i.id = t.strategy_instance_id
        where t.id = strategy_transition_actions.transition_id and i.user_id = auth.uid()
    ));

-- ---- User-owned: strategy_legs (via cycle→instance) ------------------------
alter table public.strategy_legs enable row level security;
create policy "select_own" on public.strategy_legs for select
    using (exists (
        select 1 from public.strategy_cycles c
        join public.strategy_instances i on i.id = c.strategy_instance_id
        where c.id = strategy_legs.strategy_cycle_id and i.user_id = auth.uid()
    ));
create policy "insert_own" on public.strategy_legs for insert
    with check (exists (
        select 1 from public.strategy_cycles c
        join public.strategy_instances i on i.id = c.strategy_instance_id
        where c.id = strategy_legs.strategy_cycle_id and i.user_id = auth.uid()
    ));
create policy "update_own" on public.strategy_legs for update
    using (exists (
        select 1 from public.strategy_cycles c
        join public.strategy_instances i on i.id = c.strategy_instance_id
        where c.id = strategy_legs.strategy_cycle_id and i.user_id = auth.uid()
    ));

-- ---- User-owned: collateral_snapshots (via position) -----------------------
alter table public.collateral_snapshots enable row level security;
create policy "select_own" on public.collateral_snapshots for select
    using (exists (
        select 1 from public.strategy_positions p
        where p.id = collateral_snapshots.position_id and p.user_id = auth.uid()
    ));
create policy "insert_own" on public.collateral_snapshots for insert
    with check (exists (
        select 1 from public.strategy_positions p
        where p.id = collateral_snapshots.position_id and p.user_id = auth.uid()
    ));

-- ---- User-owned: strategy_events (via instance) -----------------------------
alter table public.strategy_events enable row level security;
create policy "select_own" on public.strategy_events for select
    using (exists (
        select 1 from public.strategy_instances i
        where i.id = strategy_events.strategy_instance_id and i.user_id = auth.uid()
    ));
create policy "insert_own" on public.strategy_events for insert
    with check (exists (
        select 1 from public.strategy_instances i
        where i.id = strategy_events.strategy_instance_id and i.user_id = auth.uid()
    ));

-- ---- User-owned: alerts (read-only for user; write via service role) --------
alter table public.alerts enable row level security;
create policy "select_own" on public.alerts for select
    using (user_id = auth.uid());
-- عمداً بدون Policy برای insert/update: Alert Engine فقط با service_role
-- (که RLS را دور می‌زند) می‌نویسد؛ کاربر هرگز مستقیماً Alert نمی‌سازد.

-- ---- User-owned: telegram_links ---------------------------------------------
alter table public.telegram_links enable row level security;
create policy "select_own" on public.telegram_links for select
    using (user_id = auth.uid());
create policy "insert_own" on public.telegram_links for insert
    with check (user_id = auth.uid());
create policy "update_own" on public.telegram_links for update
    using (user_id = auth.uid());

-- ---- User-owned: subscriptions (read-only for user) --------------------------
alter table public.subscriptions enable row level security;
create policy "select_own" on public.subscriptions for select
    using (user_id = auth.uid());
-- insert/update فقط از طریق Backend/Payment Webhook با service_role.

-- ---- User-owned: performance_snapshots (via instance) -------------------------
alter table public.performance_snapshots enable row level security;
create policy "select_own" on public.performance_snapshots for select
    using (exists (
        select 1 from public.strategy_instances i
        where i.id = performance_snapshots.strategy_instance_id and i.user_id = auth.uid()
    ));
-- insert فقط از طریق Cron/Backend با service_role.

-- ---- Public catalog: قابل خواندن برای هر کاربر Authenticated، نوشتن فقط Admin --
alter table public.strategy_definitions enable row level security;
create policy "select_authenticated" on public.strategy_definitions for select
    using (auth.role() = 'authenticated');
create policy "admin_write" on public.strategy_definitions for all
    using (public.is_admin()) with check (public.is_admin());

alter table public.strategy_leg_roles enable row level security;
create policy "select_authenticated" on public.strategy_leg_roles for select
    using (auth.role() = 'authenticated');
create policy "admin_write" on public.strategy_leg_roles for all
    using (public.is_admin()) with check (public.is_admin());

alter table public.suggestion_risk_tiers enable row level security;
create policy "select_authenticated" on public.suggestion_risk_tiers for select
    using (auth.role() = 'authenticated');
create policy "admin_write" on public.suggestion_risk_tiers for all
    using (public.is_admin()) with check (public.is_admin());

alter table public.subscription_plans enable row level security;
create policy "select_authenticated" on public.subscription_plans for select
    using (auth.role() = 'authenticated');
create policy "admin_write" on public.subscription_plans for all
    using (public.is_admin()) with check (public.is_admin());

alter table public.suggestion_batches enable row level security;
create policy "select_authenticated" on public.suggestion_batches for select
    using (auth.role() = 'authenticated');
create policy "admin_write" on public.suggestion_batches for all
    using (public.is_admin()) with check (public.is_admin());

alter table public.suggestions enable row level security;
create policy "select_authenticated" on public.suggestions for select
    using (auth.role() = 'authenticated');
-- نوشتن فقط با service_role (موتور پیشنهاددهی)؛ عمداً بدون Policy برای کاربر عادی.

-- Admin-only، اما نمادهای ACTIVE باید برای کاربر عادی هم قابل مشاهده باشند
-- (چون Suggestion به آن‌ها ارجاع می‌دهد و UI باید نام/کد نماد را نشان دهد)
alter table public.symbols enable row level security;
create policy "select_active_authenticated" on public.symbols for select
    using (status = 'ACTIVE' and auth.role() = 'authenticated');
create policy "admin_all" on public.symbols for all
    using (public.is_admin()) with check (public.is_admin());

-- ---- Admin-only (بدون دسترسی خواندن برای کاربر عادی) --------------------------
alter table public.symbol_liquidity_snapshots enable row level security;
create policy "admin_all" on public.symbol_liquidity_snapshots for all
    using (public.is_admin()) with check (public.is_admin());

alter table public.strategy_rule_profiles enable row level security;
create policy "admin_all" on public.strategy_rule_profiles for all
    using (public.is_admin()) with check (public.is_admin());

alter table public.strategy_rule_definitions enable row level security;
create policy "admin_all" on public.strategy_rule_definitions for all
    using (public.is_admin()) with check (public.is_admin());

alter table public.alert_rule_definitions enable row level security;
create policy "admin_all" on public.alert_rule_definitions for all
    using (public.is_admin()) with check (public.is_admin());

alter table public.trial_settings enable row level security;
create policy "admin_all" on public.trial_settings for all
    using (public.is_admin()) with check (public.is_admin());

-- ============================================================================
-- پایان Migration اولیه
-- ============================================================================
