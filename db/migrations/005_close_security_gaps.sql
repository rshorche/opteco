-- ============================================================================
-- Opteco — 005_close_security_gaps
-- ============================================================================
-- سه شکاف امنیتی که هنگام انتقال از opteco-test به Production جا افتاده
-- بودند (نه بخشی از منطق Market Data خودِ 004، ولی هم‌زمان با آن کشف و
-- بسته شدند):
--
--   1) fn_apply_position_execution (از 001) هرگز search_path نداشت.
--   2) handle_new_auth_user (از 003) باید فقط توسط Trigger خودش صدا زده
--      شود، نه به‌عنوان RPC عمومی — چه از anon/authenticated، چه از طریق
--      گرنت پیش‌فرض PUBLIC.
--   3) revoke انجام‌شده روی is_admin() از anon، روی opteco-test اعمال شده
--      بود اما هرگز به فایل اصلی Migration برنگشت، پس روی Production جا
--      افتاده بود.
--
-- نکتهٔ فنی مهم: REVOKE از anon/authenticated به‌تنهایی کافی نیست، چون
-- Postgres به‌طور پیش‌فرض EXECUTE را به نقش PUBLIC می‌دهد و anon/authenticated
-- از PUBLIC ارث می‌برند؛ باید صریحاً از PUBLIC هم Revoke شود.
-- ============================================================================

alter function public.fn_apply_position_execution() set search_path = public, pg_catalog;

revoke execute on function public.handle_new_auth_user() from anon, authenticated, public;

revoke execute on function public.is_admin() from anon, public;
grant execute on function public.is_admin() to authenticated;
