import { createClient, SupabaseClient } from "@supabase/supabase-js";

/**
 * Service-role client — دور می‌زند RLS را. فقط داخل موتورهای Backend
 * (Suggestion Engine، Alert Engine، Cron های Performance Snapshot) استفاده شود.
 * هرگز به سمت Client/Browser expose نشود.
 */
export function getServiceRoleClient(): SupabaseClient {
  const url = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) {
    throw new Error(
      "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY تنظیم نشده‌اند."
    );
  }
  return createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * Request-scoped client — با JWT خودِ کاربر ساخته می‌شود تا RLS طبیعی اعمال شود.
 * در API Routeهایی که کاربر مستقیماً داده‌ی خودش را می‌خواند/می‌نویسد استفاده شود
 * (مثلاً ثبت Execution واقعی، مشاهده Instanceهای خودش).
 */
export function getUserScopedClient(userAccessToken: string): SupabaseClient {
  const url = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  if (!url || !anonKey) {
    throw new Error("SUPABASE_URL / SUPABASE_ANON_KEY تنظیم نشده‌اند.");
  }
  return createClient(url, anonKey, {
    global: { headers: { Authorization: `Bearer ${userAccessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
