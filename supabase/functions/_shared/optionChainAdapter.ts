import { fetchRawOptionChain, RawBrsOptionRecord } from "./brsApiClient.ts";
import { mapOptionRecord, AdaptedOptionContract, FieldMappingError } from "./fieldMapping.ts";

export interface OptionChainFetchResult {
  contracts: AdaptedOptionContract[];
  skippedCount: number;
  skippedReasons: string[]; // حداکثر چند نمونه، نه لیست کامل (جلوگیری از انفجار لاگ)
  fetchedAt: string; // ISO — زمان یکسان برای همهٔ رکوردهای همین Sync
}

const MAX_LOGGED_SKIP_REASONS = 10;

/**
 * تنها نقطهٔ ورود این ماژول برای بقیهٔ سیستم: یک درخواست HTTP کامل به
 * Market API می‌زند (نه بیشتر — طبق محدودیت سهمیهٔ روزانه)، هر دو نوع
 * CALL و PUT را Map می‌کند (فیلتر Strategy-محور اینجا انجام نمی‌شود؛ آن
 * مسئولیت candidateSelection.ts است)، و نتیجهٔ تمیز را برمی‌گرداند.
 *
 * Strategy Engine/بقیهٔ سیستم هرگز نباید مستقیم brsApiClient یا
 * fieldMapping را import کنند — فقط از همین تابع استفاده می‌شود.
 */
export async function fetchAndAdaptOptionChain(): Promise<OptionChainFetchResult> {
  const fetchedAt = new Date().toISOString();
  const rawRecords: RawBrsOptionRecord[] = await fetchRawOptionChain();

  const contracts: AdaptedOptionContract[] = [];
  const skippedReasons: string[] = [];
  let skippedCount = 0;

  for (const raw of rawRecords) {
    try {
      contracts.push(mapOptionRecord(raw));
    } catch (err) {
      skippedCount += 1;
      if (skippedReasons.length < MAX_LOGGED_SKIP_REASONS) {
        skippedReasons.push(err instanceof FieldMappingError ? err.message : "خطای نامشخص در Mapping");
      }
    }
  }

  return { contracts, skippedCount, skippedReasons, fetchedAt };
}

/**
 * گروه‌بندی قراردادهای Adapt‌شده بر اساس نماد پایه — برای Upsert در
 * symbols (fn_sync_symbol_observation) و برای ساخت ورودی Candidate
 * Selection به‌ازای هر نماد.
 */
export function groupByUnderlying(
  contracts: AdaptedOptionContract[]
): Map<string, AdaptedOptionContract[]> {
  const grouped = new Map<string, AdaptedOptionContract[]>();
  for (const c of contracts) {
    const list = grouped.get(c.underlyingSymbol) ?? [];
    list.push(c);
    grouped.set(c.underlyingSymbol, list);
  }
  return grouped;
}
