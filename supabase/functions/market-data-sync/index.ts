// Supabase Edge Function — market-data-sync
// معادل کامل app/api/market-data/sync/route.ts (نسخهٔ Vercel/Next.js)،
// اما روی Deno Runtime خودِ Supabase اجرا می‌شود — بدون هیچ وابستگی به Vercel.
//
// SUPABASE_URL و SUPABASE_SERVICE_ROLE_KEY به‌صورت خودکار و پیش‌فرض توسط
// خودِ Supabase در اختیار هر Edge Function قرار می‌گیرند (نیازی به تنظیم
// دستی نیست). BRS_API_KEY و MARKET_SYNC_INVOKE_SECRET باید دستی به‌عنوان
// Edge Function Secret تنظیم شوند (بخش گزارش را ببینید).

import { createClient } from "npm:@supabase/supabase-js@2";
import { fetchAndAdaptOptionChain, groupByUnderlying } from "../_shared/optionChainAdapter.ts";
import { BrsApiError } from "../_shared/brsApiClient.ts";
import { MARKET_DATA_SYNC_CONFIG } from "../_shared/syncConfig.ts";
import { isWithinTehranTradingWindow } from "../_shared/tehranTradingWindow.ts";
import { redactSecrets } from "../_shared/redactSecrets.ts";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  // این تابع با verify_jwt=false Deploy می‌شود (بخش گزارش را ببینید) و
  // به‌جای آن، از یک Secret اختصاصی خودمان استفاده می‌کند — دقیقاً همان
  // الگوی x-cron-secret که در نسخهٔ Vercel داشتیم.
  const invokeSecret = req.headers.get("x-invoke-secret");
  if (!invokeSecret || invokeSecret !== Deno.env.get("MARKET_SYNC_INVOKE_SECRET")) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  if (!isWithinTehranTradingWindow()) {
    return new Response(JSON.stringify({ status: "skipped", reason: "outside_trading_window" }), {
      status: 200,
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const service = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const startedAt = new Date();

  // --- Guard سهمیهٔ روزانه ---
  const { data: todaysCallCount, error: countError } = await service.rpc(
    "fn_count_todays_option_api_calls"
  );

  if (countError) {
    await service.from("market_sync_runs").insert({
      started_at: startedAt.toISOString(),
      finished_at: new Date().toISOString(),
      status: "FAILED",
      http_status: null,
      error_message: redactSecrets(`Daily guard query failed: ${countError.message}`),
      contracts_fetched: 0,
    });
    return new Response(JSON.stringify({ status: "failed", error: "Daily guard check failed" }), {
      status: 500,
    });
  }

  if ((todaysCallCount ?? 0) >= MARKET_DATA_SYNC_CONFIG.dailyApiRequestLimit) {
    await service.from("market_sync_runs").insert({
      started_at: startedAt.toISOString(),
      finished_at: new Date().toISOString(),
      status: "DAILY_LIMIT_REACHED",
      http_status: null,
      error_message: `سهمیهٔ روزانه (${MARKET_DATA_SYNC_CONFIG.dailyApiRequestLimit} درخواست) قبلاً پر شده بود؛ Option API صدا زده نشد.`,
      contracts_fetched: 0,
    });
    return new Response(JSON.stringify({ status: "daily_limit_reached" }), { status: 429 });
  }

  // --- تلاش اصلی: دقیقاً یک تماس با Option API ---
  try {
    const { contracts, skippedCount, skippedReasons, fetchedAt } = await fetchAndAdaptOptionChain();

    const grouped = groupByUnderlying(contracts);
    for (const underlyingSymbol of grouped.keys()) {
      const { error: symbolErr } = await service.rpc("fn_sync_symbol_observation", {
        p_symbol_code: underlyingSymbol,
        p_display_name: underlyingSymbol,
        p_observed_at: fetchedAt,
      });
      if (symbolErr) {
        console.error(
          redactSecrets(`fn_sync_symbol_observation failed for ${underlyingSymbol}: ${symbolErr.message}`)
        );
      }
    }

    await service.rpc("fn_deactivate_stale_symbols");

    const { data: syncRun, error: syncRunErr } = await service
      .from("market_sync_runs")
      .insert({
        started_at: startedAt.toISOString(),
        finished_at: new Date().toISOString(),
        status: "SUCCESS",
        http_status: 200,
        error_message: skippedCount > 0 ? `Skipped ${skippedCount} malformed record(s)` : null,
        contracts_fetched: contracts.length,
      })
      .select()
      .single();

    if (syncRunErr || !syncRun) {
      throw new Error(`Failed to record sync run: ${syncRunErr?.message ?? "unknown"}`);
    }

    if (contracts.length > 0) {
      const snapshotRows = contracts.map((c) => ({
        sync_run_id: syncRun.id,
        option_symbol: c.optionSymbol,
        underlying_symbol: c.underlyingSymbol,
        option_type: c.optionType,
        strike: c.strike,
        expiry_date: c.expiryDate,
        day_remain: c.dayRemain,
        contract_size: c.contractSize,
        open_interest: c.openInterest,
        bid: c.bid,
        ask: c.ask,
        last_premium: c.lastPremium,
        volume: c.volume,
        value_traded: c.valueTraded,
        underlying_spot: c.underlyingSpot,
        observed_at: fetchedAt,
        raw: c.raw,
      }));

      const { error: snapshotErr } = await service.from("market_option_snapshots").insert(snapshotRows);
      if (snapshotErr) {
        throw new Error(`Failed to insert snapshots: ${snapshotErr.message}`);
      }
    }

    return new Response(
      JSON.stringify({
        status: "success",
        contractsFetched: contracts.length,
        underlyingsSeen: grouped.size,
        skippedCount,
        skippedReasons,
      }),
      { status: 200 }
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : "خطای ناشناخته";
    await service.from("market_sync_runs").insert({
      started_at: startedAt.toISOString(),
      finished_at: new Date().toISOString(),
      status: "FAILED",
      http_status: err instanceof BrsApiError ? err.httpStatus ?? null : null,
      error_message: redactSecrets(message),
      contracts_fetched: 0,
    });

    return new Response(
      JSON.stringify({ status: "failed", error: "Sync failed; see market_sync_runs for details" }),
      { status: 500 }
    );
  }
});
