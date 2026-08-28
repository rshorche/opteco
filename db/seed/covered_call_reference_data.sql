-- ============================================================================
-- Opteco — Seed دادهٔ مرجع Covered Call (پیش‌نویس، هنوز روی Production اجرا نشده)
-- ============================================================================
-- این فایل، برخلاف db/migrations/*.sql، تغییر Schema نیست — فقط دادهٔ مرجع
-- (Catalog/Config) لازم برای فعال‌سازی جریان Covered Call است. عمداً از پوشهٔ
-- migrations جدا نگه داشته می‌شود.
--
-- ⚠️ اعداد داخل parameters هنوز تأیید نشده‌اند — placeholder برای بحث هستند.
-- ⚠️ liquidity_min_volume / liquidity_min_value_traded هنوز نیاز به دادهٔ
--    واقعی بازار (از نمونهٔ JSON) دارند تا حدسی نباشند.
-- ============================================================================

-- ۱. Strategy Definition
insert into public.strategy_definitions (code, display_name_fa, display_name_en, module_ref, is_active)
values ('covered_call', 'کاورد کال', 'Covered Call', 'strategies/covered_call', true)
on conflict (code) do nothing;

-- ۲. Leg Roles لازم برای Covered Call (Call Spread بعداً هنگام فعال‌سازی آن Strategy اضافه می‌شود)
insert into public.strategy_leg_roles (code, display_name_fa, applicable_instrument_type, description) values
    ('COVERED_UNDERLYING', 'سهم پایهٔ پوشش‌دهنده', 'STOCK', 'سهم نگهداری‌شده که وثیقهٔ Short Call است'),
    ('SHORT_CALL', 'اختیار خرید فروخته‌شده', 'OPTION', 'Call فروخته‌شده در Covered Call')
on conflict (code) do nothing;

-- ۳. Risk Tier — فقط یک سطح برای MVP (طبق تصمیم شما)
insert into public.suggestion_risk_tiers (code, display_name, sort_order, is_active)
values ('STANDARD', 'استاندارد', 1, true)
on conflict (code) do nothing;

-- ۴. Rule Profile پیش‌فرض Covered Call
-- ⚠️ تمام اعداد زیر placeholder هستند — قبل از اجرای واقعی باید با شما نهایی شوند.
insert into public.strategy_rule_profiles
    (strategy_definition_id, code, display_name, version, is_active, is_default, parameters)
values (
    (select id from public.strategy_definitions where code = 'covered_call'),
    'covered_call_default_v1',
    'پروفایل پیش‌فرض Covered Call — نسخهٔ ۱ (MVP)',
    1,
    true,
    true,
    '{
        "candidate_selection": {
            "dte_min": 15,
            "dte_max": 45,
            "max_suggestions_per_tier": 4,
            "risk_tiers": {
                "STANDARD": {
                    "target_monthly_yield_min": 0.03,
                    "liquidity_min_volume": 0,
                    "liquidity_min_value_traded": 0,
                    "max_bid_ask_spread_pct": 0.10
                }
            }
        },
        "ranking_weights": {
            "monthlyYield": 0.4,
            "safetyMargin": 0.3,
            "liquidityScore": 0.2,
            "executionRisk": 0.1
        }
    }'::jsonb
)
on conflict (code) do nothing;

-- ۵. نمادهای اولیهٔ MVP
-- ⚠️ نمادهای واقعی هنوز از شما دریافت نشده‌اند — این‌ها فقط جای‌نگه‌دارندهٔ ساختاری‌اند.
-- insert into public.symbols (symbol_code, display_name, status) values
--     ('SYMBOL1', 'نام نمایشی ۱', 'DISABLED'),
--     ('SYMBOL2', 'نام نمایشی ۲', 'DISABLED');
-- (عمداً status='DISABLED' پیش‌فرض است؛ باید صریحاً توسط Admin فعال شوند —
--  طبق اصل معماری «هر نماد جدید پیش‌فرض غیرفعال است»)
