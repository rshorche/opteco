"use client";

import { createClient } from "@supabase/supabase-js";

/**
 * کلاینت مخصوص Browser — از NEXT_PUBLIC_* می‌خواند (این مقادیر Public هستند،
 * anon key به‌طبیعتِ خودش برای افشا در Client طراحی شده؛ امنیت واقعی از RLS
 * می‌آید، نه از پنهان بودن این کلید).
 */
export function getBrowserClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL!;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
  return createClient(url, anonKey);
}
