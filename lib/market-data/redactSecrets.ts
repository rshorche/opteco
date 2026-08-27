/**
 * لایهٔ دفاع مضاعف: هر رشته‌ای (پیام خطا، لاگ، هرچیزی) که قرار است ذخیره
 * یا نمایش داده شود، از این تابع عبور می‌کند تا اگر جایی — حتی به‌اشتباه —
 * مقدار واقعی BRS_API_KEY داخلش رفته باشد، حذف شود. این علاوه بر Redact
 * کردن URL در brsApiClient.ts است، نه جایگزین آن.
 */
export function redactSecrets(message: string): string {
  const apiKey = process.env.BRS_API_KEY;
  if (!apiKey) return message;
  return message.split(apiKey).join("***REDACTED***");
}
