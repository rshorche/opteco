import { NextRequest, NextResponse } from "next/server";
import { getUserScopedClient } from "../../../../lib/supabase/client";
import { recordExecution } from "../../../../lib/strategy/lifecycle/lifecycleService";

/**
 * POST /api/positions/executions
 * بدنه: { positionId, executionType, quantity, price, executedAt, closeReason? }
 *
 * این Endpoint فقط یک Execution ثبت می‌کند؛ منبع حقیقت position_executions
 * است و strategy_positions با Trigger پایگاه‌داده به‌روز می‌شود (نه اینجا).
 */
export async function POST(req: NextRequest) {
  const accessToken = req.headers.get("authorization")?.replace("Bearer ", "");
  if (!accessToken) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = await req.json();
  const { positionId, executionType, quantity, price, executedAt, closeReason, notes } = body;

  if (!positionId || !executionType || !quantity || !price || !executedAt) {
    return NextResponse.json({ error: "فیلدهای الزامی ناقص است" }, { status: 400 });
  }

  // OPEN دیگر از این مسیر مجاز نیست — باید از /api/positions (fn_create_position)
  // استفاده شود تا Position و اولین Execution در یک تراکنش اتمیک ساخته شوند.
  if (executionType === "OPEN") {
    return NextResponse.json(
      { error: "برای ساخت Position جدید از /api/positions استفاده کنید، نه این Endpoint" },
      { status: 400 }
    );
  }

  const client = getUserScopedClient(accessToken);

  try {
    await recordExecution(client, {
      positionId,
      executionType,
      quantity,
      price,
      executedAt,
      closeReason,
      notes,
    });
    return NextResponse.json({ ok: true });
  } catch (err) {
    // پیام‌های Exception از Trigger پایگاه‌داده (مثلاً DECREASE بیش از مقدار باز)
    // مستقیماً برای کاربر قابل‌فهم هستند چون در fn_apply_position_execution
    // به فارسی/انگلیسی ساده نوشته شده‌اند.
    return NextResponse.json({ error: (err as Error).message }, { status: 422 });
  }
}
