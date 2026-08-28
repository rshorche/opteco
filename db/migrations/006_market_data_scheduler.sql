-- ============================================================================
-- Opteco — 006_market_data_scheduler (پیش‌نویس نهایی، هنوز اجرا نشده)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- ۱. افزودن وضعیت DAILY_LIMIT_REACHED به market_sync_runs
-- ----------------------------------------------------------------------------
alter table public.market_sync_runs
    drop constraint if exists market_sync_runs_status_check;
alter table public.market_sync_runs
    add constraint market_sync_runs_status_check
    check (status in ('SUCCESS', 'FAILED', 'DAILY_LIMIT_REACHED'));

-- ----------------------------------------------------------------------------
-- ۲. جدول شمارندهٔ روزانه — یک Counter عملیاتی، نه تاریخچه
--    برخلاف market_sync_runs/market_option_snapshots، UPDATE روی این جدول
--    طبیعی و مورد نیاز است (دقیقاً مثل symbols.status) — قانون Append-only
--    فقط برای دو جدول تاریخی اعمال می‌شود، نه برای این Counter عملیاتی.
--    هیچ رکورد تاریخی حذف نمی‌شود؛ این جدول فقط "امروز چند بار تماس گرفته
--    شده" را نگه می‌دارد، نه این‌که جایگزین market_sync_runs باشد.
-- ----------------------------------------------------------------------------
create table public.market_sync_daily_quota (
    tehran_date       date primary key,
    reserved_count    int not null default 0,
    updated_at        timestamptz not null default now()
);

alter table public.market_sync_daily_quota enable row level security;
create policy "admin_read_only" on public.market_sync_daily_quota for select
    using (public.is_admin());

revoke insert, update, delete on public.market_sync_daily_quota from authenticated, anon;

-- ----------------------------------------------------------------------------
-- ۳. رزرو اتمیک سهمیه — حل قطعی Race Condition
--    این UPDATE با شرط "reserved_count < p_daily_limit" در همان دستور،
--    به‌صورت ذاتی در Postgres با Row-Level Locking سریال می‌شود؛ دو
--    فراخوانی هم‌زمان هرگز نمی‌توانند هر دو موفق شوند اگر فقط یک جای خالی
--    باقی مانده باشد. هیچ Advisory Lock یا هماهنگی سطح Application لازم
--    نیست، و هیچ تراکنشی در طول تماس HTTP واقعی به BRS API باز نمی‌ماند
--    (این تابع فقط چند میلی‌ثانیه طول می‌کشد، قبل از شروع تماس HTTP).
-- ----------------------------------------------------------------------------
create or replace function public.fn_try_reserve_option_api_call(
    p_daily_limit int
)
returns boolean
language plpgsql
set search_path = public, pg_catalog
as $$
declare
    v_today      date := (now() at time zone 'Asia/Tehran')::date;
    v_new_count  int;
begin
    insert into public.market_sync_daily_quota (tehran_date, reserved_count)
    values (v_today, 0)
    on conflict (tehran_date) do nothing;

    update public.market_sync_daily_quota
    set reserved_count = reserved_count + 1,
        updated_at = now()
    where tehran_date = v_today
      and reserved_count < p_daily_limit
    returning reserved_count into v_new_count;

    -- اگر ردیفی Update نشد (چون سهمیه پر بود)، v_new_count همچنان NULL
    -- می‌ماند و هیچ افزایشی هم اتفاق نیفتاده — یعنی تلاش‌های رد‌شده هرگز
    -- سهمیه را مصنوعی پر نمی‌کنند.
    return v_new_count is not null;
end;
$$;

revoke execute on function public.fn_try_reserve_option_api_call(int) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- ۴. Vault — Secret احراز هویت pg_net→Edge Function
--    شما مقدار واقعی را جایگزین 'YOUR_RANDOM_SECRET_HERE' می‌کنید (باید
--    دقیقاً همان مقداری باشد که در Edge Function Secret با نام
--    MARKET_SYNC_INVOKE_SECRET تنظیم می‌کنید).
-- ----------------------------------------------------------------------------
select vault.create_secret(
    'YOUR_RANDOM_SECRET_HERE',
    'market_sync_invoke_secret',
    'Secret احراز هویت pg_net هنگام صدا زدن market-data-sync Edge Function'
);

-- ----------------------------------------------------------------------------
-- ۵. Scheduler پویا — ارتقای آیندهٔ سهمیه فقط یک فراخوانی تابع است
--    شما PROJECT_REF واقعی را در مقدار پیش‌فرض p_edge_function_url
--    جایگزین می‌کنید.
-- ----------------------------------------------------------------------------
create or replace function public.fn_reschedule_market_data_sync(
    p_num_slots int default 9,
    p_edge_function_url text default 'https://<PROJECT_REF>.supabase.co/functions/v1/market-data-sync'
)
returns void
language plpgsql
as $$
declare
    v_start_minutes  int := 5 * 60 + 30;  -- 05:30 UTC = 09:00 تهران
    v_end_minutes    int := 9 * 60;       -- 09:00 UTC = 12:30 تهران
    v_step           numeric;
    v_slot           int;
    v_minutes_of_day int;
    v_job_name       text;
begin
    perform cron.unschedule(jobname) from cron.job where jobname like 'market-sync-%';

    v_step := (v_end_minutes - v_start_minutes)::numeric / greatest(p_num_slots - 1, 1);

    for v_slot in 0 .. p_num_slots - 1 loop
        v_minutes_of_day := v_start_minutes + round(v_step * v_slot);
        v_job_name := format('market-sync-%s', lpad(v_slot::text, 2, '0'));

        perform cron.schedule(
            v_job_name,
            format('%s %s * * 0,1,2,3,6', v_minutes_of_day % 60, v_minutes_of_day / 60),
            format($job$
                select net.http_post(
                    url := %L,
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json',
                        'x-invoke-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'market_sync_invoke_secret')
                    ),
                    body := '{}'::jsonb
                );
            $job$, p_edge_function_url)
        );
    end loop;
end;
$$;

-- اجرای اولیه با ۹ Slot (طبق سهمیهٔ فعلی ۱۰ درخواستی)
select public.fn_reschedule_market_data_sync(9);

-- روز ارتقا به پلن ۱۰۰۰ درخواستی، فقط همین یک خط لازم است، هیچ SQL دیگری:
-- select public.fn_reschedule_market_data_sync(<عدد جدید Slot>);
