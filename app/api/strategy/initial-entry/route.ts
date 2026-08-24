import { NextRequest, NextResponse } from "next/server";
import { getUserScopedClient } from "../../../../lib/supabase/client";
import { recordInitialEntry } from "../../../../lib/strategy/lifecycle/lifecycleService";

/**
 * POST /api/strategy/initial-entry
 * بدنه: {
 *   strategyDefinitionId, underlyingSymbol, entrySource, entrySuggestionId,
 *   legs: [{ position_id, role_code }]
 * }
 *
 * پیش‌نیاز: کاربر باید قبلاً از طریق /api/positions/executions هر Position
 * (سهم + اختیار فروخته‌شده) را با یک Execution از نوع OPEN ثبت کرده باشد.
 * این Endpoint فقط اتصال آن Positionها به یک StrategyInstance/Cycle جدید
 * را به‌صورت اتمیک انجام می‌دهد.
 */
export async function POST(req: NextRequest) {
  const accessToken = req.headers.get("authorization")?.replace("Bearer ", "");
  if (!accessToken) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const client = getUserScopedClient(accessToken);

  // شناسهٔ کاربر از خودِ JWT گرفته می‌شود، نه از بدنهٔ درخواست (جلوگیری از جعل)
  const { data: userData, error: userErr } = await client.auth.getUser();
  if (userErr || !userData?.user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = await req.json();
  const { strategyDefinitionId, underlyingSymbol, entrySource, entrySuggestionId, legs } = body;

  if (!strategyDefinitionId || !underlyingSymbol || !entrySource || !Array.isArray(legs) || legs.length === 0) {
    return NextResponse.json({ error: "فیلدهای الزامی ناقص است" }, { status: 400 });
  }

  try {
    const result = await recordInitialEntry(client, {
      userId: userData.user.id,
      strategyDefinitionId,
      underlyingSymbol,
      entrySource,
      entrySuggestionId: entrySuggestionId ?? null,
      legs,
    });
    return NextResponse.json(result);
  } catch (err) {
    return NextResponse.json({ error: (err as Error).message }, { status: 422 });
  }
}
