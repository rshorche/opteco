import { RawBrsOptionRecord } from "./brsApiClient.ts";

export type MappedOptionType = "CALL" | "PUT";

/**
 * مدل داخلی نهایی Opteco برای یک قرارداد اختیار — تنها شکلی که بقیهٔ سیستم
 * (Strategy Engine، ذخیره‌سازی در market_option_snapshots) مجاز است ببیند.
 * نام هیچ فیلد خام BrsApi (مثل price_strike، l18، pl) از این فایل بیرون
 * نمی‌رود.
 */
export interface AdaptedOptionContract {
  optionSymbol: string;
  underlyingSymbol: string;
  underlyingId: number | null;
  optionType: MappedOptionType;
  strike: number;
  expiryDate: string; // ISO (YYYY-MM-DD)، میلادی
  dayRemain: number;
  contractSize: number;
  openInterest: number | null;
  bid: number;
  ask: number;
  lastPremium: number; // = pl، بدون هیچ Fallback به pc یا فیلد دیگر
  volume: number;
  valueTraded: number;
  underlyingSpot: number;
  raw: RawBrsOptionRecord;
}

export class FieldMappingError extends Error {}

// ============================================================================
// تبدیل تاریخ شمسی → میلادی
// الگوریتم استاندارد و عمومی Borkowski (همان مبنای کتابخانه‌های شناخته‌شدهٔ
// jalaali)؛ به‌صورت خودمختار پیاده‌سازی شده تا Dependency جدیدی اضافه نشود.
// هر سه تابع کمکی pure و بدون وابستگی به هم به‌صورت مستقل قابل تست‌اند.
// ============================================================================

function divTrunc(a: number, b: number): number {
  return Math.trunc(a / b);
}

function modTrunc(a: number, b: number): number {
  return a - Math.trunc(a / b) * b;
}

/** نقاط جهش تقویم شمسی (Break Points) — ثابت و استاندارد */
const JALALI_BREAKS = [
  -61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181, 1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394,
  2456, 3178,
];

function computeJalaliCalendarInfo(jalaliYear: number): { gregorianYear: number; marchDay: number } {
  const breaksCount = JALALI_BREAKS.length;
  const gregorianYear = jalaliYear + 621;

  if (jalaliYear < JALALI_BREAKS[0] || jalaliYear >= JALALI_BREAKS[breaksCount - 1]) {
    throw new FieldMappingError(`سال شمسی خارج از بازهٔ پشتیبانی‌شده: ${jalaliYear}`);
  }

  let leapJalali = -14;
  let previousBreak = JALALI_BREAKS[0];
  let jump = 0;

  for (let i = 1; i < breaksCount; i += 1) {
    const currentBreak = JALALI_BREAKS[i];
    jump = currentBreak - previousBreak;
    if (jalaliYear < currentBreak) break;
    leapJalali += divTrunc(jump, 33) * 8 + divTrunc(modTrunc(jump, 33), 4);
    previousBreak = currentBreak;
  }

  let n = jalaliYear - previousBreak;
  leapJalali += divTrunc(n, 33) * 8 + divTrunc(modTrunc(n, 33) + 3, 4);
  if (modTrunc(jump, 33) === 4 && jump - n === 4) leapJalali += 1;

  const leapGregorian = divTrunc(gregorianYear, 4) - divTrunc((divTrunc(gregorianYear, 100) + 1) * 3, 4) - 150;
  const marchDay = 20 + leapJalali - leapGregorian;

  return { gregorianYear, marchDay };
}

function gregorianToJulianDayNumber(gy: number, gm: number, gd: number): number {
  let d =
    divTrunc((gy + divTrunc(gm - 8, 6) + 100100) * 1461, 4) +
    divTrunc(153 * modTrunc(gm + 9, 12) + 2, 5) +
    gd -
    34840408;
  d = d - divTrunc(divTrunc(gy + 100100 + divTrunc(gm - 8, 6), 100) * 3, 4) + 752;
  return d;
}

function jalaliToJulianDayNumber(jy: number, jm: number, jd: number): number {
  const { gregorianYear, marchDay } = computeJalaliCalendarInfo(jy);
  return gregorianToJulianDayNumber(gregorianYear, 3, marchDay) + (jm - 1) * 31 - divTrunc(jm, 7) * (jm - 7) + jd - 1;
}

function julianDayNumberToGregorian(jdn: number): { gy: number; gm: number; gd: number } {
  let j = 4 * jdn + 139361631;
  j = j + divTrunc(divTrunc(4 * jdn + 183187720, 146097) * 3, 4) * 4 - 3908;
  const i = divTrunc(modTrunc(j, 1461), 4) * 5 + 308;
  const gd = divTrunc(modTrunc(i, 153), 5) + 1;
  const gm = modTrunc(divTrunc(i, 153), 12) + 1;
  const gy = divTrunc(j, 1461) - 100100 + divTrunc(8 - gm, 6);
  return { gy, gm, gd };
}

/**
 * تبدیل یک تاریخ شمسی به فرمت "YYYY-MM-DD" (مثل "1405-06-25") به رشتهٔ
 * ISO میلادی معادل (مثل "2026-09-16"). تابعی pure و مستقل، بدون I/O —
 * به همین دلیل به‌سادگی قابل Unit Test است.
 */
export function jalaliToIsoDate(jalaliDate: string): string {
  const parts = jalaliDate.split("-").map((p) => parseInt(p, 10));
  if (parts.length !== 3 || parts.some((n) => Number.isNaN(n))) {
    throw new FieldMappingError(`فرمت تاریخ شمسی نامعتبر: "${jalaliDate}"`);
  }
  const [jy, jm, jd] = parts;
  if (jm < 1 || jm > 12 || jd < 1 || jd > 31) {
    throw new FieldMappingError(`تاریخ شمسی خارج از بازهٔ معتبر: "${jalaliDate}"`);
  }

  const { gy, gm, gd } = julianDayNumberToGregorian(jalaliToJulianDayNumber(jy, jm, jd));
  const mm = String(gm).padStart(2, "0");
  const dd = String(gd).padStart(2, "0");
  return `${gy}-${mm}-${dd}`;
}

// ============================================================================
// Mapping اصلی هر رکورد
// ============================================================================

function mapOptionType(raw: string | undefined): MappedOptionType {
  const normalized = (raw ?? "").trim().toUpperCase();
  if (normalized === "CALL") return "CALL";
  if (normalized === "PUT") return "PUT";
  throw new FieldMappingError(`نوع اختیار نامعتبر یا ناشناخته: "${raw}"`);
}

/**
 * تبدیل یک رکورد خام BrsApi به مدل داخلی Opteco.
 * این تنها جایی در کل پروژه است که نام فیلدهای خام BrsApi (l18, base_l18,
 * price_strike, pl, ...) ظاهر می‌شود. Strategy Engine و بقیهٔ سیستم فقط
 * AdaptedOptionContract را می‌بینند.
 */
export function mapOptionRecord(raw: RawBrsOptionRecord): AdaptedOptionContract {
  if (!raw.base_l18 || !raw.l18 || !raw.date_end || raw.price_strike == null) {
    throw new FieldMappingError(
      `رکورد ناقص است (base_l18/l18/date_end/price_strike الزامی‌اند): ${JSON.stringify({
        l18: raw.l18 ?? null,
        base_l18: raw.base_l18 ?? null,
      })}`
    );
  }

  // Premium = فقط pl، طبق تصمیم قطعی؛ ?? 0 فقط جایگزین null/undefined است
  // (یعنی «معامله‌ای ثبت نشده»)، نه Fallback منطقی به فیلد دیگری مثل pc.
  const lastPremium = raw.pl ?? 0;

  // قیمت سهم پایه: آخرین معاملهٔ واقعی (base_pl) اگر مثبت باشد، وگرنه
  // قیمت پایانی (base_pc) — چون ممکن است سهم امروز هنوز معامله نشده باشد.
  const underlyingSpot = (raw.base_pl ?? 0) > 0 ? (raw.base_pl as number) : raw.base_pc ?? 0;

  return {
    optionSymbol: raw.l18,
    underlyingSymbol: raw.base_l18,
    underlyingId: raw.base_id ?? null,
    optionType: mapOptionType(raw.type),
    strike: raw.price_strike,
    expiryDate: jalaliToIsoDate(raw.date_end),
    dayRemain: raw.day_remain ?? 0,
    contractSize: raw.size_contract ?? 0,
    openInterest: raw.interest_open ?? null,
    bid: raw.pd1 ?? 0,
    ask: raw.po1 ?? 0,
    lastPremium,
    volume: raw.tvol ?? 0,
    valueTraded: raw.tval ?? 0,
    underlyingSpot,
    raw,
  };
}
