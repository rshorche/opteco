"use client";

import { useState } from "react";
import { getBrowserClient } from "../../../lib/supabase/browserClient";

export default function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [status, setStatus] = useState<"idle" | "loading" | "done" | "error">("idle");
  const [message, setMessage] = useState("");
  const [profile, setProfile] = useState<Record<string, unknown> | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setStatus("loading");
    setMessage("");
    setProfile(null);

    const supabase = getBrowserClient();
    const { data: authData, error: authError } = await supabase.auth.signInWithPassword({ email, password });

    if (authError) {
      setStatus("error");
      setMessage(authError.message);
      return;
    }

    // بررسی این‌که Trigger واقعاً ردیف public.users را ساخته و RLS اجازهٔ
    // دیدن آن را به خودِ کاربر می‌دهد (این دقیقاً تست خواسته‌شدهٔ شماست)
    const { data: userRow, error: userError } = await supabase
      .from("users")
      .select("*")
      .eq("id", authData.user!.id)
      .single();

    if (userError) {
      setStatus("error");
      setMessage(`ورود موفق بود ولی خواندن پروفایل شکست خورد: ${userError.message}`);
      return;
    }

    setStatus("done");
    setMessage("ورود موفق. ردیف public.users با موفقیت خوانده شد (یعنی Trigger + RLS هر دو درست کار کرده‌اند).");
    setProfile(userRow);
  }

  return (
    <main>
      <h1>ورود</h1>
      <form onSubmit={handleSubmit} style={{ display: "flex", flexDirection: "column", gap: "0.75rem", maxWidth: 320 }}>
        <input
          type="email"
          placeholder="ایمیل"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
        />
        <input
          type="password"
          placeholder="رمز عبور"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
        />
        <button type="submit" disabled={status === "loading"}>
          {status === "loading" ? "در حال ورود..." : "ورود"}
        </button>
      </form>
      {message && <p style={{ color: status === "error" ? "crimson" : "green" }}>{message}</p>}
      {profile && (
        <pre style={{ background: "#f4f4f4", padding: "1rem", direction: "ltr", textAlign: "left" }}>
          {JSON.stringify(profile, null, 2)}
        </pre>
      )}
    </main>
  );
}
