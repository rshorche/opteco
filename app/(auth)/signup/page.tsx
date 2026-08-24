"use client";

import { useState, FormEvent } from "react";
import { getBrowserClient } from "../../../lib/supabase/browserClient";

export default function SignupPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [status, setStatus] = useState<"idle" | "loading" | "done" | "error">("idle");
  const [message, setMessage] = useState("");

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setStatus("loading");
    setMessage("");

    const supabase = getBrowserClient();
    const { data, error } = await supabase.auth.signUp({ email, password });

    if (error) {
      setStatus("error");
      setMessage(error.message);
      return;
    }

    setStatus("done");
    setMessage(
      data.user?.identities?.length === 0
        ? "این ایمیل قبلاً ثبت شده است."
        : "ثبت‌نام انجام شد. اگر تأیید ایمیل فعال باشد، ایمیل خود را بررسی کنید؛ در غیر این صورت اکنون می‌توانید وارد شوید."
    );
  }

  return (
    <main>
      <h1>ثبت‌نام</h1>
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
          placeholder="رمز عبور (حداقل ۶ کاراکتر)"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          minLength={6}
          required
        />
        <button type="submit" disabled={status === "loading"}>
          {status === "loading" ? "در حال ثبت‌نام..." : "ثبت‌نام"}
        </button>
      </form>
      {message && <p style={{ color: status === "error" ? "crimson" : "green" }}>{message}</p>}
      <p>
        <a href="/login">قبلاً ثبت‌نام کرده‌اید؟ ورود</a>
      </p>
    </main>
  );
}
