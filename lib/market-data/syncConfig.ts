/**
 * تنظیمات مرکزی Sync بازار — تنها جایی در کل پروژه که این اعداد تعریف
 * می‌شوند. برای ارتقا از پلن رایگان (۱۰ درخواست/روز) به پلن ۱۰۰۰
 * درخواستی، فقط همین فایل تغییر می‌کند؛ هیچ عدد دیگری جای دیگری از کد
 * Hard-code نشده است.
 */
export const MARKET_DATA_SYNC_CONFIG = {
  /**
   * سقف مطلق درخواست‌های واقعی به Option API در یک روز تقویمی تهران —
   * شامل اجراهای Cron، دستی، و هر Retry. Daily Request Guard این عدد را
   * رعایت می‌کند، مستقل از این‌که چه چیزی Route را صدا زده.
   */
  dailyApiRequestLimit: 10,

  /**
   * چند مورد از این سهمیه برای اجرای برنامه‌ریزی‌شدهٔ pg_cron در نظر
   * گرفته می‌شود؛ باقی‌مانده (dailyApiRequestLimit - scheduledRunsPerDay)
   * به‌عنوان ظرفیت اضطراری/دستی نگه داشته می‌شود.
   */
  scheduledRunsPerDay: 9,

  /** بازهٔ ساعات معاملاتی تهران که در آن Sync اصلاً معنی دارد */
  tradingWindow: {
    startHour: 9,
    startMinute: 0,
    endHour: 12,
    endMinute: 30,
  },

  /** روزهای معاملاتی بازار ایران (شنبه تا چهارشنبه) */
  tradingWeekdays: ["Sat", "Sun", "Mon", "Tue", "Wed"] as const,
} as const;
