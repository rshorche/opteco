/**
 * نسخهٔ Deno — منطق کاملاً یکسان با lib/market-data/redactSecrets.ts،
 * فقط Deno.env.get به‌جای process.env.
 */
export function redactSecrets(message: string): string {
  const apiKey = Deno.env.get("BRS_API_KEY");
  if (!apiKey) return message;
  return message.split(apiKey).join("***REDACTED***");
}
