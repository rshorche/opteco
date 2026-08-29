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
-- ۴. Vault — قبلاً توسط شما مستقیماً انجام شده (تأیید شد: Secret با نام
--    market_sync_invoke_secret در vault.secrets موجود است). این بخش دیگر
--    اجرا نمی‌شود تا آن Secret موجود دست‌نخورده بماند.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- ۵. Scheduler — گام ثابت + سقف توقف صریح (نه تقسیم خودکار کل بازه)
--    با p_step_minutes=25 و توقف در 12:20 تهران، دقیقاً همین ۹ زمان تولید
--    می‌شود: 09:00, 09:25, 09:50, 10:15, 10:40, 11:05, 11:30, 11:55, 12:20
-- ----------------------------------------------------------------------------
create or replace function public.fn_reschedule_market_data_sync(
    p_step_minutes int default 25,
    p_last_call_hour int default 12,
    p_last_call_minute int default 20,
    p_edge_function_url text default 'https://flfafjrpdqlohndiecsz.supabase.co/functions/v1/market-data-sync'
)
returns void
language plpgsql
as $$
declare
    v_start_minutes      int := 5 * 60 + 30;  -- 05:30 UTC = 09:00 تهران
    v_tehran_offset      int := 210;           -- UTC+3:30 (ثابت، بدون DST)
    v_last_call_minutes  int;
    v_minutes_of_day     int;
    v_slot               int := 0;
    v_job_name           text;
begin
    perform cron.unschedule(jobname) from cron.job where jobname like 'market-sync-%';

    v_last_call_minutes := (p_last_call_hour * 60 + p_last_call_minute) - v_tehran_offset;
    v_minutes_of_day := v_start_minutes;

    while v_minutes_of_day <= v_last_call_minutes loop
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

        v_minutes_of_day := v_minutes_of_day + p_step_minutes;
        v_slot := v_slot + 1;
    end loop;
end;
$$;

-- اجرای اولیه: دقیقاً همان ۹ زمان درخواستی شما
select public.fn_reschedule_market_data_sync(25, 12, 20);

-- در آینده، بعد از ارتقای API، فقط با تغییر گام/سقف توقف (نه بازطراحی):
-- select public.fn_reschedule_market_data_sync(<گام جدید>, <ساعت پایان>, <دقیقه پایان>);
-- (برای فرکانس بسیار بالا مثل هر ۱ دقیقه، این الگوی "N Job مجزا" احتمالاً
--  باید با یک Cron Expression تکرارشونده جایگزین شود، نه صدها Job جدا —
--  آن یک تصمیم طراحی جداگانه در زمان ارتقا خواهد بود.)
