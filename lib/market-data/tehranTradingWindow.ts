import { MARKET_DATA_SYNC_CONFIG } from "./syncConfig";

/**
 * بررسی این‌که آیا یک لحظهٔ مشخص (پیش‌فرض: الان) داخل بازهٔ معاملاتی تهران
 * است یا نه. عمداً از Intl.DateTimeFormat (تابع داخلی و تست‌شدهٔ خودِ
 * JavaScript برای IANA Timezone) استفاده شده، نه محاسبهٔ دستی آفست UTC+3:30
 * — دقیقاً به همان دلیلی که در fieldMapping.ts یک باگ محاسباتی دستی پیدا
 * شد: هرجا معادل استاندارد و تست‌شده وجود دارد، به آن اعتماد می‌کنیم.
 */
export function isWithinTehranTradingWindow(now: Date = new Date()): boolean {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Tehran",
    hour: "numeric",
    minute: "numeric",
    weekday: "short",
    hour12: false,
  }).formatToParts(now);

  const get = (type: string) => parts.find((p) => p.type === type)?.value;
  const hour = parseInt(get("hour") ?? "0", 10);
  const minute = parseInt(get("minute") ?? "0", 10);
  const weekday = get("weekday");

  const isTradingDay = (MARKET_DATA_SYNC_CONFIG.tradingWeekdays as readonly string[]).includes(
    weekday ?? ""
  );

  const { startHour, startMinute, endHour, endMinute } = MARKET_DATA_SYNC_CONFIG.tradingWindow;
  const minutesNow = hour * 60 + minute;
  const windowStart = startHour * 60 + startMinute;
  const windowEnd = endHour * 60 + endMinute;

  return isTradingDay && minutesNow >= windowStart && minutesNow <= windowEnd;
}
