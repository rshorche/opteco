const BRS_OPTION_ENDPOINT = "https://Api.BrsApi.ir/Tsetmc/Option.php";

export interface RawBrsOptionRecord {
  time?: string;
  base_l18?: string;
  base_id?: number;
  l18?: string;
  id?: number;
  type?: string;
  date_begin?: string;
  date_end?: string;
  day_remain?: number;
  size_contract?: number;
  price_strike?: number;
  interest_open?: number;
  base_py?: number;
  base_pl?: number;
  base_pc?: number;
  pl?: number;
  pc?: number;
  tvol?: number;
  tval?: number;
  pd1?: number;
  po1?: number;
  [key: string]: unknown;
}

export class BrsApiError extends Error {
  constructor(message: string, public readonly httpStatus?: number) {
    super(message);
    this.name = "BrsApiError";
  }
}

/**
 * نسخهٔ Deno این فایل — منطق کاملاً یکسان با lib/market-data/brsApiClient.ts
 * (نسخهٔ Node/Vercel)؛ تنها تفاوت خواندن Secret با Deno.env.get به‌جای
 * process.env است. اگر منطق این تابع تغییر کرد، نسخهٔ Node هم باید هم‌گام
 * به‌روزرسانی شود (فعلاً این دو فایل دستی هم‌گام نگه داشته می‌شوند، نه از
 * طریق یک منبع مشترک Build-time).
 */
export async function fetchRawOptionChain(): Promise<RawBrsOptionRecord[]> {
  const apiKey = Deno.env.get("BRS_API_KEY");
  if (!apiKey) {
    throw new BrsApiError("BRS_API_KEY تنظیم نشده است (Edge Function Secret خالی است)");
  }

  const url = `${BRS_OPTION_ENDPOINT}?key=${apiKey}`;
  const redactedUrl = `${BRS_OPTION_ENDPOINT}?key=***`;

  let response: Response;
  try {
    response = await fetch(url, { cache: "no-store" });
  } catch (err) {
    throw new BrsApiError(
      `درخواست به Market API ناموفق بود (${redactedUrl}): ${
        err instanceof Error ? err.message : "خطای ناشناخته"
      }`
    );
  }

  if (!response.ok) {
    throw new BrsApiError(
      `Market API با وضعیت ${response.status} پاسخ داد (${redactedUrl})`,
      response.status
    );
  }

  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new BrsApiError(`پاسخ Market API قابل Parse به JSON نبود (${redactedUrl})`);
  }

  if (!Array.isArray(body)) {
    throw new BrsApiError("پاسخ Market API آرایه نبود — فرمت غیرمنتظره");
  }

  return body as RawBrsOptionRecord[];
}
