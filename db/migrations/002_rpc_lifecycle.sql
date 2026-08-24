-- ============================================================================
-- Opteco — RPCهای اتمیک Strategy Lifecycle (نسخهٔ نهایی پس از Hardening + Review)
-- این فایل معادل دقیق چیزی است که روی پروژهٔ opteco-test اعمال و تست شده.
-- ============================================================================

create or replace function public.fn_create_position(
    p_instrument_type   text,
    p_underlying_symbol text,
    p_option_type       text,
    p_strike_price      numeric,
    p_expiry_date       date,
    p_option_symbol     text,
    p_contract_size     numeric,
    p_direction         text,
    p_quantity          numeric,
    p_price             numeric,
    p_executed_at       timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    v_user_id     uuid := auth.uid();
    v_position_id uuid;
begin
    if v_user_id is null then
        raise exception 'Unauthorized: no authenticated user';
    end if;

    insert into public.strategy_positions
        (user_id, instrument_type, underlying_symbol, option_type, strike_price, expiry_date,
         option_symbol, contract_size, direction, quantity, entry_price, entry_date, status)
    values
        (v_user_id, p_instrument_type, p_underlying_symbol, p_option_type, p_strike_price, p_expiry_date,
         p_option_symbol, p_contract_size, p_direction, p_quantity, p_price, p_executed_at, 'OPEN')
    returning id into v_position_id;

    insert into public.position_executions (position_id, execution_type, quantity, price, executed_at)
    values (v_position_id, 'OPEN', p_quantity, p_price, p_executed_at);

    return v_position_id;
end;
$$;

create or replace function public.fn_check_position_has_open_execution()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    if not exists (
        select 1 from public.position_executions
        where position_id = new.id and execution_type = 'OPEN'
    ) then
        raise exception 'Data integrity violation: strategy_position % has no OPEN position_execution', new.id;
    end if;
    return new;
end;
$$;

drop trigger if exists trg_position_requires_open_execution on public.strategy_positions;
create constraint trigger trg_position_requires_open_execution
    after insert on public.strategy_positions
    deferrable initially deferred
    for each row
    execute function public.fn_check_position_has_open_execution();

create or replace function public.fn_record_collateral_for_cycle(
    p_cycle_id      uuid,
    p_transition_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    v_short_leg          record;
    v_cover_position_id  uuid;
    v_coverage_type      text;
begin
    for v_short_leg in
        select l.position_id
        from public.strategy_legs l
        join public.strategy_positions p on p.id = l.position_id
        where l.strategy_cycle_id = p_cycle_id
          and l.detached_at is null
          and p.direction = 'SHORT'
    loop
        v_cover_position_id := null;

        select l2.position_id into v_cover_position_id
            from public.strategy_legs l2
            join public.strategy_leg_roles r2 on r2.id = l2.role_id
            where l2.strategy_cycle_id = p_cycle_id
              and l2.detached_at is null
              and r2.code = 'COVERED_UNDERLYING'
            limit 1;

        if v_cover_position_id is not null then
            v_coverage_type := 'COVERED_BY_STOCK';
        else
            select l2.position_id into v_cover_position_id
                from public.strategy_legs l2
                join public.strategy_positions p2 on p2.id = l2.position_id
                where l2.strategy_cycle_id = p_cycle_id
                  and l2.detached_at is null
                  and p2.direction = 'LONG'
                  and p2.instrument_type = 'OPTION'
                limit 1;

            if v_cover_position_id is not null then
                v_coverage_type := 'COVERED_BY_LONG_OPTION';
            else
                v_coverage_type := 'NAKED';
            end if;
        end if;

        insert into public.collateral_snapshots
            (position_id, transition_id, coverage_type, coverage_source_position_id, margin_required)
        values
            (v_short_leg.position_id, p_transition_id, v_coverage_type, v_cover_position_id, null);
    end loop;
end;
$$;

create or replace function public.fn_record_initial_entry(
    p_strategy_definition_id uuid,
    p_underlying_symbol      text,
    p_entry_source           text,
    p_entry_suggestion_id    uuid,
    p_legs                   jsonb
)
returns table(instance_id uuid, cycle_id uuid)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    v_user_id     uuid := auth.uid();
    v_instance_id uuid;
    v_cycle_id    uuid;
    v_leg         jsonb;
    v_role_id     uuid;
    v_position    public.strategy_positions%rowtype;
begin
    if v_user_id is null then
        raise exception 'Unauthorized: no authenticated user';
    end if;
    if p_entry_source not in ('SUGGESTED', 'MANUAL') then
        raise exception 'Invalid entry_source: %', p_entry_source;
    end if;
    if p_legs is null or jsonb_array_length(p_legs) = 0 then
        raise exception 'At least one leg is required for initial entry';
    end if;

    for v_leg in select * from jsonb_array_elements(p_legs)
    loop
        select * into v_position from public.strategy_positions
            where id = (v_leg->>'position_id')::uuid;
        if v_position is null then
            raise exception 'Position % not found', (v_leg->>'position_id');
        end if;
        if v_position.user_id <> v_user_id then
            raise exception 'Position % does not belong to the current user', v_position.id;
        end if;
        if v_position.status <> 'OPEN' then
            raise exception 'Position % is not OPEN (status=%)', v_position.id, v_position.status;
        end if;
        if exists (select 1 from public.strategy_legs where position_id = v_position.id and detached_at is null) then
            raise exception 'Position % is already attached as an open leg elsewhere', v_position.id;
        end if;
        if not exists (select 1 from public.position_executions where position_id = v_position.id and execution_type = 'OPEN') then
            raise exception 'Position % has no OPEN execution recorded', v_position.id;
        end if;
    end loop;

    insert into public.strategy_instances (user_id, underlying_symbol, status)
    values (v_user_id, p_underlying_symbol, 'ACTIVE')
    returning id into v_instance_id;

    insert into public.strategy_cycles
        (strategy_instance_id, strategy_definition_id, origin_type, entry_source, entry_suggestion_id)
    values
        (v_instance_id, p_strategy_definition_id, 'INITIAL_ENTRY', p_entry_source, p_entry_suggestion_id)
    returning id into v_cycle_id;

    for v_leg in select * from jsonb_array_elements(p_legs)
    loop
        select id into v_role_id from public.strategy_leg_roles where code = (v_leg->>'role_code');
        if v_role_id is null then
            raise exception 'Unknown leg role code: %', (v_leg->>'role_code');
        end if;
        insert into public.strategy_legs (strategy_cycle_id, position_id, role_id)
        values (v_cycle_id, (v_leg->>'position_id')::uuid, v_role_id);
    end loop;

    perform public.fn_record_collateral_for_cycle(v_cycle_id, null);

    insert into public.strategy_events (strategy_instance_id, event_type, ref_table, ref_id)
    values (v_instance_id, 'INSTANCE_STARTED', 'strategy_cycles', v_cycle_id);

    return query select v_instance_id, v_cycle_id;
end;
$$;

create or replace function public.fn_record_transition(
    p_instance_id          uuid,
    p_from_cycle_id        uuid,
    p_to_definition_id     uuid,
    p_transition_type      text,
    p_reason               jsonb,
    p_triggered_by         text,
    p_actions              jsonb
)
returns table(transition_id uuid, to_cycle_id uuid, instance_status text)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    v_user_id        uuid := auth.uid();
    v_instance       public.strategy_instances%rowtype;
    v_from_cycle     public.strategy_cycles%rowtype;
    v_transition_id  uuid;
    v_new_cycle_id   uuid := null;
    v_action         jsonb;
    v_action_type    text;
    v_role_before_id uuid;
    v_role_after_id  uuid;
    v_final_status   text;
    v_position       public.strategy_positions%rowtype;
begin
    if v_user_id is null then
        raise exception 'Unauthorized: no authenticated user';
    end if;

    select * into v_instance from public.strategy_instances where id = p_instance_id;
    if v_instance is null then raise exception 'Instance % not found', p_instance_id; end if;
    if v_instance.user_id <> v_user_id then raise exception 'Instance % does not belong to the current user', p_instance_id; end if;
    if v_instance.status <> 'ACTIVE' then raise exception 'Instance % is not ACTIVE (status=%)', p_instance_id, v_instance.status; end if;

    select * into v_from_cycle from public.strategy_cycles where id = p_from_cycle_id for update;
    if v_from_cycle is null then raise exception 'Cycle % not found', p_from_cycle_id; end if;
    if v_from_cycle.strategy_instance_id <> p_instance_id then
        raise exception 'Cycle % does not belong to instance %', p_from_cycle_id, p_instance_id;
    end if;
    if v_from_cycle.status <> 'OPEN' then
        raise exception 'Cycle % is not OPEN (status=%) — it may already have an outgoing transition', p_from_cycle_id, v_from_cycle.status;
    end if;

    if p_actions is null or jsonb_array_length(p_actions) = 0 then
        raise exception 'At least one action is required for a transition';
    end if;

    for v_action in select * from jsonb_array_elements(p_actions)
    loop
        select * into v_position from public.strategy_positions where id = (v_action->>'position_id')::uuid;
        if v_position is null then raise exception 'Position % not found', (v_action->>'position_id'); end if;
        if v_position.user_id <> v_user_id then raise exception 'Position % does not belong to the current user', v_position.id; end if;

        v_action_type := v_action->>'action';

        if v_action_type in ('CLOSED', 'CARRIED', 'RELEASED', 'MODIFIED') then
            if not exists (
                select 1 from public.strategy_legs
                where strategy_cycle_id = p_from_cycle_id and position_id = v_position.id and detached_at is null
            ) then
                raise exception 'Position % is not an open leg of cycle %', v_position.id, p_from_cycle_id;
            end if;
        elsif v_action_type = 'OPENED' then
            if exists (select 1 from public.strategy_legs where position_id = v_position.id and detached_at is null) then
                raise exception 'Position % is already an open leg elsewhere; cannot OPEN', v_position.id;
            end if;
            if not exists (select 1 from public.position_executions where position_id = v_position.id and execution_type = 'OPEN') then
                raise exception 'Position % has no OPEN execution recorded', v_position.id;
            end if;
        else
            raise exception 'Unknown action type: %', v_action_type;
        end if;

        if v_action_type = 'CLOSED' and v_position.status <> 'CLOSED' then
            raise exception 'Action CLOSED for position % requires a real CLOSE execution first (current status=%)', v_position.id, v_position.status;
        end if;
        if v_action_type in ('CARRIED', 'OPENED', 'RELEASED', 'MODIFIED') and v_position.status <> 'OPEN' then
            raise exception 'Action % for position % requires the position to be OPEN (current status=%)', v_action_type, v_position.id, v_position.status;
        end if;
    end loop;

    insert into public.strategy_transitions
        (strategy_instance_id, from_cycle_id, to_cycle_id, transition_type, reason, triggered_by, user_confirmed)
    values
        (p_instance_id, p_from_cycle_id, null, p_transition_type, p_reason, p_triggered_by, true)
    returning id into v_transition_id;

    if p_to_definition_id is not null then
        insert into public.strategy_cycles
            (strategy_instance_id, strategy_definition_id, origin_type, origin_transition_id, entry_source)
        values
            (p_instance_id, p_to_definition_id, 'TRANSITION', v_transition_id, 'MANUAL')
        returning id into v_new_cycle_id;

        update public.strategy_transitions set to_cycle_id = v_new_cycle_id where id = v_transition_id;
    end if;

    update public.strategy_cycles set status = 'CLOSED', closed_at = now() where id = p_from_cycle_id;

    for v_action in select * from jsonb_array_elements(p_actions)
    loop
        v_role_before_id := null;
        v_role_after_id  := null;
        v_action_type := v_action->>'action';

        if (v_action->>'role_before_code') is not null then
            select id into v_role_before_id from public.strategy_leg_roles where code = (v_action->>'role_before_code');
            if v_role_before_id is null then raise exception 'Unknown role_before_code: %', (v_action->>'role_before_code'); end if;
        end if;
        if (v_action->>'role_after_code') is not null then
            select id into v_role_after_id from public.strategy_leg_roles where code = (v_action->>'role_after_code');
            if v_role_after_id is null then raise exception 'Unknown role_after_code: %', (v_action->>'role_after_code'); end if;
        end if;

        if v_action_type in ('CARRIED', 'OPENED') and v_role_after_id is null then
            raise exception 'Action % for position % requires a valid role_after_code', v_action_type, (v_action->>'position_id');
        end if;

        insert into public.strategy_transition_actions
            (transition_id, position_id, action, role_before_id, role_after_id, detail)
        values
            (v_transition_id, (v_action->>'position_id')::uuid, v_action_type, v_role_before_id, v_role_after_id, coalesce(v_action->'detail', '{}'::jsonb));

        if v_action_type in ('CLOSED', 'RELEASED') then
            update public.strategy_legs set detached_at = now()
                where strategy_cycle_id = p_from_cycle_id and position_id = (v_action->>'position_id')::uuid and detached_at is null;

        elsif v_action_type = 'CARRIED' and v_new_cycle_id is not null then
            update public.strategy_legs set detached_at = now()
                where strategy_cycle_id = p_from_cycle_id and position_id = (v_action->>'position_id')::uuid and detached_at is null;
            insert into public.strategy_legs (strategy_cycle_id, position_id, role_id)
            values (v_new_cycle_id, (v_action->>'position_id')::uuid, v_role_after_id);

        elsif v_action_type = 'OPENED' and v_new_cycle_id is not null then
            insert into public.strategy_legs (strategy_cycle_id, position_id, role_id)
            values (v_new_cycle_id, (v_action->>'position_id')::uuid, v_role_after_id);
        end if;
    end loop;

    if v_new_cycle_id is not null then
        perform public.fn_record_collateral_for_cycle(v_new_cycle_id, v_transition_id);
    end if;

    insert into public.strategy_events (strategy_instance_id, event_type, ref_table, ref_id)
    values (p_instance_id, 'TRANSITION_RECORDED', 'strategy_transitions', v_transition_id);

    if v_new_cycle_id is null then
        update public.strategy_instances set status = 'CLOSED', closed_at = now() where id = p_instance_id;
        insert into public.strategy_events (strategy_instance_id, event_type, ref_table, ref_id)
        values (p_instance_id, 'INSTANCE_CLOSED', 'strategy_transitions', v_transition_id);
        v_final_status := 'CLOSED';
    else
        v_final_status := 'ACTIVE';
    end if;

    return query select v_transition_id, v_new_cycle_id, v_final_status;
end;
$$;

grant execute on function public.fn_create_position(text, text, text, numeric, date, text, numeric, text, numeric, numeric, timestamptz) to authenticated;
grant execute on function public.fn_record_initial_entry(uuid, text, text, uuid, jsonb) to authenticated;
grant execute on function public.fn_record_transition(uuid, uuid, uuid, text, jsonb, text, jsonb) to authenticated;

revoke execute on function public.fn_create_position(text, text, text, numeric, date, text, numeric, text, numeric, numeric, timestamptz) from anon, public;
revoke execute on function public.fn_record_initial_entry(uuid, text, text, uuid, jsonb) from anon, public;
revoke execute on function public.fn_record_transition(uuid, uuid, uuid, text, jsonb, text, jsonb) from anon, public;

revoke execute on function public.fn_record_collateral_for_cycle(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.fn_check_position_has_open_execution() from public, anon, authenticated;

revoke insert on public.strategy_positions from authenticated;
revoke insert on public.collateral_snapshots from authenticated;
revoke insert, update on public.strategy_cycles from authenticated;
revoke insert, update on public.strategy_transitions from authenticated;
revoke insert, update on public.strategy_legs from authenticated;
revoke insert, update on public.strategy_transition_actions from authenticated;

alter table public.strategy_transition_actions
    add constraint chk_role_after_required_for_carried_opened
    check (action not in ('CARRIED','OPENED') or role_after_id is not null);

create unique index if not exists uq_one_transition_per_from_cycle
    on public.strategy_transitions (from_cycle_id);
