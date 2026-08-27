import { NextRequest, NextResponse } from "next/server";
import { getServiceRoleClient } from "../../../../lib/supabase/client";
import { fetchAndAdaptOptionChain, groupByUnderlying } from "../../../../lib/market-data/optionChainAdapter";
import { BrsApiError } from "../../../../lib/market-data/brsApiClient";
import { MARKET_DATA_SYNC_CONFIG } from "../../../../lib/market-data/syncConfig";
import { isWithinTehranTradingWindow } from "../../../../lib/market-data/tehranTradingWindow";
import { redactSecrets } from "../../../../lib/market-data/redactSecrets";

/**
 * POST /api/market-data/sync
 *
 * محافظت‌شده با یک Secret مشترک (نه JWT کاربر — این یک تماس سیستمی از
 * pg_cron است، نه یک درخواست کاربر). pg_cron هر ۲۵ دقیقه، ۲۴ ساعته این
 * Route را صدا می‌زند؛ خودِ Route تشخیص می‌دهد که آیا الان داخل بازهٔ
 * معاملاتی تهران هست یا نه — این باعث می‌شود منطق «فقط ساعات بازار» به‌جای
 * Cron Expression شکننده (که مبتنی بر UTC است)، در کد ساده و قابل‌تست
 * بماند.
 *
 * ترتیب Guardها (به همین ترتیب، هرکدام می‌تواند بدون تماس با Option API
 * برگردد):
 *   1) Secret نامعتبر → 401، هیچ نوشتنی در Database.
 *   2) خارج از بازهٔ معاملاتی → 200 با skipped=true، هیچ نوشتنی در Database
 *      (این یک «عدم‌تلاش عمدی» است، نه شکست یا محدودیت).
 *   3) سهمیهٔ روزانه پر شده → یک رکورد نهایی با status='DAILY_LIMIT_REACHED'
 *      در market_sync_runs، بدون تماس با Option API.
 *   4) در غیر این صورت: دقیقاً یک تماس با Option API.
 */
export async function POST(req: NextRequest) {
  const cronSecret = req.headers.get("x-cron-secret");
  if (!cronSecret || cronSecret !== process.env.MARKET_SYNC_CRON_SECRET) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  if (!isWithinTehranTradingWindow()) {
    return NextResponse.json({ status: "skipped", reason: "outside_trading_window" });
  }

  const service = getServiceRoleClient();
  const startedAt = new Date();

  // --- Guard سهمیهٔ روزانه: حتی اجرای دستی/Retry هم از همین مسیر عبور می‌کند ---
  const { data: todaysCallCount, error: countError } = await service.rpc(
    "fn_count_todays_option_api_calls"
  );

  if (countError) {
    // اگر خودِ شمارش شکست بخورد، محافظه‌کارانه رفتار می‌کنیم: Sync را متوقف
    // می‌کنیم و آن را به‌عنوان یک شکست ثبت می‌کنیم، نه این‌که به‌صورت
    // خوش‌بینانه به Option API نفوذ کنیم.
    await service.from("market_sync_runs").insert({
      started_at: startedAt.toISOString(),
      finished_at: new Date().toISOString(),
      status: "FAILED",
      http_status: null,
      error_message: redactSecrets(`Daily guard query failed: ${countError.message}`),
      contracts_fetched: 0,
    });
    return NextResponse.json({ status: "failed", error: "Daily guard check failed" }, { status: 500 });
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
    return NextResponse.json({ status: "daily_limit_reached" }, { status: 429 });
  }

  // --- تلاش اصلی: دقیقاً یک تماس با Option API (داخل fetchAndAdaptOptionChain) ---
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
        // یک نماد ناموفق در Upsert کل Sync را متوقف نمی‌کند؛ فقط لاگ می‌شود
        // و ادامه می‌دهیم (بقیهٔ نمادها و همهٔ Snapshotها همچنان معتبرند).
        console.error(redactSecrets(`fn_sync_symbol_observation failed for ${underlyingSymbol}: ${symbolErr.message}`));
      }
    }

    // نمادهایی که مدت طولانی دیده نشده‌اند را خودکار غیرفعال کن (فقط
    // symbols.status تغییر می‌کند؛ هیچ Snapshot ای لمس نمی‌شود)
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

    return NextResponse.json({
      status: "success",
      contractsFetched: contracts.length,
      underlyingsSeen: grouped.size,
      skippedCount,
      skippedReasons,
    });
  } catch (err) {
    // یک INSERT نهایی و واحد با status='FAILED' — طبق قانون Append-only،
    // هیچ ردیف "RUNNING" ای هرگز نوشته نشده بود که حالا لازم باشد Update شود.
    const message = err instanceof Error ? err.message : "خطای ناشناخته";
    await service.from("market_sync_runs").insert({
      started_at: startedAt.toISOString(),
      finished_at: new Date().toISOString(),
      status: "FAILED",
      http_status: err instanceof BrsApiError ? err.httpStatus ?? null : null,
      error_message: redactSecrets(message),
      contracts_fetched: 0,
    });

    return NextResponse.json({ status: "failed", error: "Sync failed; see market_sync_runs for details" }, { status: 500 });
  }
}
