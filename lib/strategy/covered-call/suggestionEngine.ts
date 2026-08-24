import { getServiceRoleClient } from "../../supabase/client";
import {
  selectCoveredCallCandidates,
  RawOptionChainEntry,
  CandidateSelectionParams,
} from "./candidateSelection";
import { rankAndSelectTop, RankingWeights } from "./ranking";

/**
 * runSuggestionEngine
 * فقط برای Cron/Admin (با service_role) — یک دور کامل موتور پیشنهاددهی را
 * روی همهٔ نمادهای ACTIVE اجرا می‌کند.
 *
 * این تابع عمداً از app/api/covered-call/suggestions/route.ts جدا شده، چون
 * در Next.js App Router فایل‌های route.ts فقط اجازهٔ Export متدهای HTTP
 * (GET/POST/...) را دارند؛ هر Export دیگری خطای Build می‌دهد.
 *
 * نکته: دریافت زنجیرهٔ اختیار واقعی از Market API در این نسخهٔ Vertical Slice
 * پیاده‌سازی نشده (وابسته به تصمیم نهایی دربارهٔ Provider که هنوز تأیید نشده)
 * — اینجا امضای تابع و نقطهٔ اتصال دقیق مشخص شده تا جایگذاری آن ساده باشد.
 */
export async function runSuggestionEngine(
  fetchOptionChain: (symbolCode: string) => Promise<{ spot: number; chain: RawOptionChainEntry[] }>
) {
  const service = getServiceRoleClient();

  const { data: profile, error: profileErr } = await service
    .from("strategy_rule_profiles")
    .select("id, parameters, strategy_definition_id")
    .eq("is_default", true)
    .single();
  if (profileErr || !profile) throw new Error("Rule profile پیش‌فرض یافت نشد");

  const params = profile.parameters.candidate_selection as {
    dte_min: number;
    dte_max: number;
    max_suggestions_per_tier: number;
    risk_tiers: Record<
      string,
      { target_monthly_yield_min: number; liquidity_min_volume: number; liquidity_min_value_traded: number; max_bid_ask_spread_pct: number }
    >;
  };
  const weights = profile.parameters.ranking_weights as RankingWeights;

  const { data: tiers } = await service.from("suggestion_risk_tiers").select("*").eq("is_active", true);
  const { data: symbols } = await service.from("symbols").select("*").eq("status", "ACTIVE");

  const selectionParams: CandidateSelectionParams = {
    dteMin: params.dte_min,
    dteMax: params.dte_max,
    riskTiers: (tiers ?? []).map((t) => ({
      code: t.code,
      targetMonthlyYieldMin: params.risk_tiers[t.code]?.target_monthly_yield_min ?? 0.03,
      liquidityMinVolume: params.risk_tiers[t.code]?.liquidity_min_volume ?? 0,
      liquidityMinValueTraded: params.risk_tiers[t.code]?.liquidity_min_value_traded ?? 0,
      maxBidAskSpreadPct: params.risk_tiers[t.code]?.max_bid_ask_spread_pct ?? 0.1,
    })),
  };

  const { data: batch, error: batchErr } = await service
    .from("suggestion_batches")
    .insert({ strategy_definition_id: profile.strategy_definition_id, rule_profile_id: profile.id })
    .select()
    .single();
  if (batchErr || !batch) throw new Error("ساخت Batch ناموفق بود");

  const allCandidatesByTier: Record<string, ReturnType<typeof selectCoveredCallCandidates>> = {};

  for (const sym of symbols ?? []) {
    const { spot, chain } = await fetchOptionChain(sym.symbol_code);
    const candidates = selectCoveredCallCandidates(sym.symbol_code, spot, chain, selectionParams);
    for (const c of candidates) {
      allCandidatesByTier[c.risk_tier_code] ??= [];
      allCandidatesByTier[c.risk_tier_code].push(c);
    }
  }

  const rowsToInsert: Record<string, unknown>[] = [];
  for (const [tierCode, candidates] of Object.entries(allCandidatesByTier)) {
    const tierId = tiers?.find((t) => t.code === tierCode)?.id;
    const top = rankAndSelectTop(candidates, weights, params.max_suggestions_per_tier ?? 4);
    top.forEach((c, idx) => {
      const symbolId = symbols?.find((s) => s.symbol_code === c.symbol_code)?.id;
      rowsToInsert.push({
        batch_id: batch.id,
        symbol_id: symbolId,
        risk_tier_id: tierId,
        candidate_instrument: {
          option_symbol: c.option_symbol,
          strike: c.strike,
          expiry: c.expiry,
          option_type: c.option_type,
          contract_size: c.contract_size,
        },
        computed_metrics: {
          break_even: c.break_even,
          max_profit: c.max_profit,
          max_loss: c.max_loss,
          monthly_yield: c.monthly_yield,
          safety_margin_pct: c.safety_margin_pct,
        },
        market_data_snapshot: {
          spot_price: c.spot_price,
          bid: c.bid,
          ask: c.ask,
          volume: c.volume,
          value_traded: c.value_traded,
          captured_at: new Date().toISOString(),
        },
        rank: idx + 1,
        expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      });
    });
  }

  if (rowsToInsert.length > 0) {
    const { error: insertErr } = await service.from("suggestions").insert(rowsToInsert);
    if (insertErr) throw new Error(`ثبت Suggestionها ناموفق بود: ${insertErr.message}`);
  }

  return { batchId: batch.id, suggestionsGenerated: rowsToInsert.length };
}
