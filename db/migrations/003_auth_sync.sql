-- ============================================================================
-- Opteco — 003_auth_sync
-- اتصال auth.users (مدیریت‌شده توسط Supabase Auth) به public.users
-- ============================================================================
-- هر بار که یک کاربر واقعی از طریق Sign-up ثبت‌نام می‌کند (INSERT در auth.users
-- توسط خودِ Supabase Auth انجام می‌شود)، این Trigger به‌طور خودکار یک ردیف
-- متناظر با role='USER' در public.users می‌سازد. هیچ تغییری در هستهٔ
-- Lifecycle (001/002) ایجاد نمی‌شود؛ این کاملاً یک قطعهٔ مستقل و جدید است.

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
    insert into public.users (id, role)
    values (new.id, 'USER')
    on conflict (id) do nothing;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row
    execute function public.handle_new_auth_user();
