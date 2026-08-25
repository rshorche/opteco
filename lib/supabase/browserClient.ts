"use client";

import { createClient } from "@supabase/supabase-js";

/**
 * کلاینت مخصوص Browser — از NEXT_PUBLIC_* می‌خواند (این مقادیر Public هستند،
 * anon key به‌طبیعتِ خودش برای افشا در Client طراحی شده؛ امنیت واقعی از RLS
 * می‌آید، نه از پنهان بودن این کلید).
 *
 * عمداً از "!" استفاده نمی‌کنیم و صریحاً بررسی می‌کنیم — اگر این متغیرها روی
 * Vercel تنظیم نشده باشند، به‌جای یک Exception مبهم که در جاهای دیگر ممکن
 * است Catch نشود، همین‌جا یک پیام روشن می‌دهیم.
 */
export function getBrowserClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!url || !anonKey) {
    throw new Error(
      "پیکربندی ناقص: NEXT_PUBLIC_SUPABASE_URL یا NEXT_PUBLIC_SUPABASE_ANON_KEY " +
        "روی این Deployment تنظیم نشده‌اند. باید در Vercel Project Settings → " +
        "Environment Variables اضافه شوند."
    );
  }

  return createClient(url, anonKey);
}
