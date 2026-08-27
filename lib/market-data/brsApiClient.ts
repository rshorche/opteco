const BRS_OPTION_ENDPOINT = "https://Api.BrsApi.ir/Tsetmc/Option.php";

/**
 * شکل خام یک رکورد از پاسخ Option.php — فقط فیلدهایی که در پروژه استفاده
 * می‌شوند تایپ‌گذاری شده‌اند؛ بقیهٔ فیلدهای خام API نادیده گرفته می‌شوند
 * (نه حذف، فقط Type ندارند — چون در fieldMapping.ts کامل raw نگه داشته می‌شود).
 */
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
 * تنها یک HTTP Fetch خام به Option.php — هیچ Mapping/Transform ای اینجا
 * انجام نمی‌شود (آن مسئولیت fieldMapping.ts است).
 *
 * قوانین امنیتی:
 *  - کلید API فقط از process.env.BRS_API_KEY خوانده می‌شود.
 *  - کلید هرگز در پیام خطا یا هر جای دیگری Log/Throw نمی‌شود؛ همیشه یک نسخهٔ
 *    Redact‌شده از URL برای خطاها استفاده می‌شود.
 *  - این تابع فقط باید از سمت سرور (API Route/Job) صدا زده شود، نه از Browser
 *    (چون BRS_API_KEY یک Secret سمت سرور است، نه NEXT_PUBLIC).
 */
export async function fetchRawOptionChain(): Promise<RawBrsOptionRecord[]> {
  const apiKey = process.env.BRS_API_KEY;
  if (!apiKey) {
    throw new BrsApiError("BRS_API_KEY تنظیم نشده است (Environment Variable خالی است)");
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
