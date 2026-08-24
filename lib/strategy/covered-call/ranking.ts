import { SuggestionCandidate } from "../../supabase/types";

export interface RankingWeights {
  monthlyYield: number;
  safetyMargin: number;
  liquidityScore: number;
  executionRisk: number;
}

function normalize(value: number, min: number, max: number): number {
  if (max === min) return 0.5;
  return Math.min(1, Math.max(0, (value - min) / (max - min)));
}

/**
 * رتبه‌بندی Candidateهای یک Risk Tier (از همهٔ نمادها) و انتخاب N مورد برتر.
 * Tierها با هم رقابت نمی‌کنند — این تابع باید جدا برای هر Tier فراخوانی شود.
 */
export function rankAndSelectTop(
  candidates: SuggestionCandidate[],
  weights: RankingWeights,
  maxSuggestions: number
): SuggestionCandidate[] {
  if (candidates.length === 0) return [];

  const yields = candidates.map((c) => c.monthly_yield);
  const margins = candidates.map((c) => c.safety_margin_pct);
  const liquidity = candidates.map((c) => c.value_traded);
  const spreadRisk = candidates.map((c) => (c.ask - c.bid) / (c.ask || 1));

  const yMin = Math.min(...yields), yMax = Math.max(...yields);
  const mMin = Math.min(...margins), mMax = Math.max(...margins);
  const lMin = Math.min(...liquidity), lMax = Math.max(...liquidity);
  const sMin = Math.min(...spreadRisk), sMax = Math.max(...spreadRisk);

  const scored = candidates.map((c) => {
    const yieldScore = normalize(c.monthly_yield, yMin, yMax);
    const marginScore = normalize(c.safety_margin_pct, mMin, mMax);
    const liquidityScore = normalize(c.value_traded, lMin, lMax);
    const spread = (c.ask - c.bid) / (c.ask || 1);
    const executionRiskScore = 1 - normalize(spread, sMin, sMax); // اسپرد کمتر = امتیاز بیشتر

    const score =
      weights.monthlyYield * yieldScore +
      weights.safetyMargin * marginScore +
      weights.liquidityScore * liquidityScore +
      weights.executionRisk * executionRiskScore;

    return { candidate: c, score };
  });

  return scored
    .sort((a, b) => b.score - a.score)
    .slice(0, maxSuggestions)
    .map((s) => s.candidate);
}
