-- ============================================================================
-- Opteco — 004_market_data (پیش‌نویس — هنوز اجرا نشده، فقط برای Review)
-- ============================================================================
-- قانون معماری قطعی این دامنه:
--   market_sync_runs و market_option_snapshots کاملاً Append-only هستند.
--   هیچ UPDATE یا DELETE ای روی این دو جدول مجاز نیست — نه توسط Application،
--   نه توسط هیچ Trigger/RPC آینده. اگر روزی Retention/Archive لازم شد، آن
--   یک تصمیم جداگانه و صریح خواهد بود، نه چیزی که در این Migration پیش‌بینی
--   شده باشد.
--   symbols برخلاف این دو، همچنان یک جدول "وضعیت فعلی" است و UPDATE رویش
--   طبیعی و مجاز است (تغییر status/last_seen_at)، اما هرگز DELETE نمی‌شود.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. گسترش symbols (فقط دو ستون جدید، بدون تغییر ساختاری در بقیه)
-- ----------------------------------------------------------------------------

alter table public.symbols add column if not exists last_seen_at timestamptz;
alter table public.symbols add column if not exists auto_disabled_at timestamptz;

comment on column public.symbols.auto_disabled_at is
    'زمانی که سیستم (نه Admin) این نماد را به‌خاطر عدم مشاهده در Market Data غیرفعال کرده. '
    'اگر NULL باشد یعنی وضعیت فعلی (چه ACTIVE چه DISABLED) نتیجهٔ تصمیم دستی Admin است و '
    'سیستم هرگز نباید آن را خودکار تغییر دهد. هر اقدام دستی آیندهٔ Admin روی این نماد باید '
    'این فیلد را صراحتاً NULL کند تا این قرارداد حفظ شود.';

-- ----------------------------------------------------------------------------
-- 2. market_sync_runs — تاریخچهٔ کامل هر تلاش Sync (Append-only)
-- ----------------------------------------------------------------------------

create table public.market_sync_runs (
    id                    uuid primary key default gen_random_uuid(),
    started_at              timestamptz not null,
    finished_at               timestamptz not null,   -- همیشه مقداردهی‌شده؛ چون فقط بعد از اتمام کامل INSERT می‌شود
    status                      text not null check (status in ('SUCCESS', 'FAILED')),
    http_status                   int,
    error_message                    text,
    contracts_fetched                  int not null default 0,
    created_at                           timestamptz not null default now()
);

create index idx_sync_runs_started_at on public.market_sync_runs (started_at desc);

-- ----------------------------------------------------------------------------
-- 3. market_option_snapshots — یک ردیف به‌ازای هر قرارداد در هر Sync (Append-only)
-- ----------------------------------------------------------------------------

create table public.market_option_snapshots (
    id                    uuid primary key default gen_random_uuid(),
    sync_run_id              uuid not null references public.market_sync_runs(id),
    option_symbol               text not null,
    underlying_symbol              text not null,
    option_type                       text not null check (option_type in ('CALL', 'PUT')),
    strike                               numeric not null,
    expiry_date                            date not null,
    day_remain                                int not null,
    contract_size                                numeric not null,
    open_interest                                   numeric,
    bid                                                numeric,
    ask                                                   numeric,
    last_premium                                             numeric,   -- = pl (آخرین معامله)، طبق تصمیم شما
    volume                                                      numeric,
    value_traded                                                   numeric,
    underlying_spot                                                   numeric,
    observed_at                                                          timestamptz not null,  -- زمان یکسان برای همهٔ ردیف‌های یک Sync
    raw                                                                     jsonb not null,       -- رکورد خام کامل، برای Audit/آینده
    created_at                                                                timestamptz not null default now()
);

create index idx_snapshots_underlying_time on public.market_option_snapshots (underlying_symbol, observed_at desc);
create index idx_snapshots_option_time on public.market_option_snapshots (option_symbol, observed_at desc);
create index idx_snapshots_sync_run on public.market_option_snapshots (sync_run_id);

-- ----------------------------------------------------------------------------
-- 4. قفل صریح Append-only در سطح GRANT — حتی اگر یک باگ آینده در کد سعی کند
--    UPDATE/DELETE بزند، خودِ Database اجازه نمی‌دهد (نه فقط قرارداد در کد).
-- ----------------------------------------------------------------------------

revoke update, delete on public.market_sync_runs from authenticated, anon;
revoke update, delete on public.market_option_snapshots from authenticated, anon;
revoke insert on public.market_sync_runs from authenticated, anon;      -- فقط service_role (از داخل Route) می‌نویسد
revoke insert on public.market_option_snapshots from authenticated, anon;

-- ----------------------------------------------------------------------------
-- 5. RLS — این دو جدول داده خام بازارند؛ کاربر عادی مستقیم نباید ببیندشان
--    (طبق اصل معماری: خروجی نهایی کاربر فقط از طریق جدول suggestions است)
-- ----------------------------------------------------------------------------

alter table public.market_sync_runs enable row level security;
create policy "admin_read_only" on public.market_sync_runs for select
    using (public.is_admin());

alter table public.market_option_snapshots enable row level security;
create policy "admin_read_only" on public.market_option_snapshots for select
    using (public.is_admin());

-- ----------------------------------------------------------------------------
-- 6. توابع مدیریت وضعیت symbols — فقط UPDATE روی symbols (مجاز)، هرگز DELETE
--    و هرگز لمس market_sync_runs/market_option_snapshots
-- ----------------------------------------------------------------------------

-- هر بار یک نماد پایه در یک Sync موفق دیده شود، این تابع صدا زده می‌شود.
-- نماد جدید → همیشه DISABLED ساخته می‌شود (طبق اصل قدیمی: Admin باید صریحاً فعال کند).
-- نماد موجود → فقط last_seen_at به‌روز می‌شود؛ اگر status فعلی نتیجهٔ
--   غیرفعال‌سازی خودکار بوده (auto_disabled_at NOT NULL)، خودکار به ACTIVE برمی‌گردد.
--   اگر غیرفعال‌سازی دستی Admin بوده (auto_disabled_at NULL)، دست‌نخورده می‌ماند.
create or replace function public.fn_sync_symbol_observation(
    p_symbol_code   text,
    p_display_name  text,
    p_observed_at   timestamptz
)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    insert into public.symbols (symbol_code, display_name, status, last_seen_at)
    values (p_symbol_code, p_display_name, 'DISABLED', p_observed_at)
    on conflict (symbol_code) do update
    set
        last_seen_at = excluded.last_seen_at,
        status = case
            when public.symbols.status = 'DISABLED' and public.symbols.auto_disabled_at is not null
                then 'ACTIVE'
            else public.symbols.status
        end,
        auto_disabled_at = case
            when public.symbols.status = 'DISABLED' and public.symbols.auto_disabled_at is not null
                then null
            else public.symbols.auto_disabled_at
        end;
end;
$$;

-- بعد از هر Sync موفق صدا زده می‌شود: هر نمادی که مدت طولانی دیده نشده،
-- خودکار غیرفعال می‌شود (فقط symbols.status تغییر می‌کند، هیچ داده تاریخی حذف نمی‌شود).
create or replace function public.fn_deactivate_stale_symbols(
    p_stale_after_days int default 45
)
returns int
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
    v_count int;
begin
    update public.symbols
    set status = 'DISABLED', auto_disabled_at = now()
    where status = 'ACTIVE'
      and last_seen_at is not null
      and last_seen_at < now() - (p_stale_after_days || ' days')::interval;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

-- این دو تابع فقط باید از مسیر سرور (service_role، از داخل Route ما) صدا زده شوند.
revoke execute on function public.fn_sync_symbol_observation(text, text, timestamptz) from public, anon, authenticated;
revoke execute on function public.fn_deactivate_stale_symbols(int) from public, anon, authenticated;
