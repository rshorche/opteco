import { SuggestionCandidate } from "../../supabase/types";

/**
 * ورودی خام یک قرارداد از زنجیرهٔ اختیار (Market API)، پیش از هر پردازش.
 * منبع: Market Data Layer / Adapter — نه Skill، نه Cache دائمی.
 */
export interface RawOptionChainEntry {
  optionSymbol: string;
  optionType: "CALL" | "PUT";
  strike: number;
  expiryDate: string; // ISO date
  contractSize: number;
  bid: number;
  ask: number;
  lastPremium: number;
  volume: number;
  valueTraded: number;
}

export interface RiskTierParams {
  code: string; // 'LOW' | 'MEDIUM' | 'HIGH' | ...
  targetMonthlyYieldMin: number; // مثلاً 0.03 = 3%
  liquidityMinVolume: number;
  liquidityMinValueTraded: number;
  maxBidAskSpreadPct: number;
}

export interface CandidateSelectionParams {
  dteMin: number;
  dteMax: number;
  riskTiers: RiskTierParams[];
}

/** فاصلهٔ روز تا سررسید */
function daysToExpiry(expiryDateIso: string, asOf: Date): number {
  const expiry = new Date(expiryDateIso);
  return Math.round((expiry.getTime() - asOf.getTime()) / (1000 * 60 * 60 * 24));
}

/**
 * بازده ماهانه‌شدهٔ فروش یک Call پوشش‌داده‌شده با سهم:
 * (Premium دریافتی / قیمت فعلی سهم) نرمال‌شده به ۳۰ روز.
 * فرمول پایه (Premium/Spot) از iran-option می‌آید؛ نرمال‌سازی ماهانه منطق خودِ Opteco است.
 */
function monthlyizedYield(premium: number, spot: number, dte: number): number {
  if (spot <= 0 || dte <= 0) return 0;
  const rawYield = premium / spot;
  return rawYield * (30 / dte);
}

function breakEven(spot: number, premium: number): number {
  // Covered Call: Break-even = قیمت خرید سهم - Premium دریافتی (فرمول iran-option)
  return spot - premium;
}

function maxProfit(strike: number, spot: number, premium: number, contractSize: number): number {
  return ((strike - spot) + premium) * contractSize;
}

/**
 * الگوریتم Candidate Selection — نسخهٔ مستند نهایی:
 *   برای هر (نماد × Risk Tier): از بین قراردادهای OTM نزدیک به یک ماه،
 *   اولین موردی که بازده ماهانهٔ هدفِ همان Tier را تأمین کند، Candidate اصلی است؛
 *   سپس نقدشوندگی/اسپرد آن Tier اعمال می‌شود؛ در صورت رد، به OTM بعدی می‌رویم.
 */
export function selectCoveredCallCandidates(
  symbolCode: string,
  spotPrice: number,
  optionChain: RawOptionChainEntry[],
  params: CandidateSelectionParams,
  asOf: Date = new Date()
): SuggestionCandidate[] {
  const results: SuggestionCandidate[] = [];

  // 1-3: فیلتر DTE + OTM (فقط Call)، مرتب‌شده از نزدیک‌ترین Strike به دورترین
  const otmCandidates = optionChain
    .filter((c) => c.optionType === "CALL")
    .filter((c) => c.strike > spotPrice)
    .map((c) => ({ ...c, dte: daysToExpiry(c.expiryDate, asOf) }))
    .filter((c) => c.dte >= params.dteMin && c.dte <= params.dteMax)
    .sort((a, b) => a.strike - b.strike);

  for (const tier of params.riskTiers) {
    let candidateFound: SuggestionCandidate | null = null;

    for (const opt of otmCandidates) {
      const premium = opt.lastPremium;
      const yieldMonthly = monthlyizedYield(premium, spotPrice, opt.dte);

      // مرحلهٔ ۶: اولین OTM که بازده هدف این Tier را برآورده کند
      if (yieldMonthly < tier.targetMonthlyYieldMin) continue;

      // مرحلهٔ ۷: فیلتر نقدشوندگی/اسپرد همان Tier
      const spreadPct = opt.ask > 0 ? (opt.ask - opt.bid) / opt.ask : 1;
      const liquidityOk =
        opt.volume >= tier.liquidityMinVolume &&
        opt.valueTraded >= tier.liquidityMinValueTraded &&
        spreadPct <= tier.maxBidAskSpreadPct;

      if (!liquidityOk) continue; // برو سراغ OTM بعدی در حلقه

      const be = breakEven(spotPrice, premium);
      const mp = maxProfit(opt.strike, spotPrice, premium, opt.contractSize);

      candidateFound = {
        symbol_code: symbolCode,
        risk_tier_code: tier.code,
        option_symbol: opt.optionSymbol,
        strike: opt.strike,
        expiry: opt.expiryDate,
        option_type: "CALL",
        contract_size: opt.contractSize,
        spot_price: spotPrice,
        premium,
        bid: opt.bid,
        ask: opt.ask,
        volume: opt.volume,
        value_traded: opt.valueTraded,
        monthly_yield: yieldMonthly,
        break_even: be,
        max_profit: mp,
        max_loss: be * opt.contractSize, // سناریوی بدترین حالت: سهم به صفر برسد
        safety_margin_pct: (opt.strike - spotPrice) / spotPrice,
      };
      break; // مرحلهٔ ۸: حداکثر یک Candidate به‌ازای این (نماد × Tier)
    }

    if (candidateFound) results.push(candidateFound);
    // اگر هیچ Candidate ای رد نشد و به انتها رسیدیم → هیچ‌چیز برای این Tier
    // اضافه نمی‌شود (بهتر از پیشنهاد ضعیف، طبق بند ۲۴ سند معماری)
  }

  return results;
}
