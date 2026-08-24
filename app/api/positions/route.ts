import { NextRequest, NextResponse } from "next/server";
import { getUserScopedClient } from "../../../lib/supabase/client";
import { createPosition } from "../../../lib/strategy/lifecycle/lifecycleService";

/**
 * POST /api/positions
 * ساخت یک Position جدید (سهم یا اختیار) به‌همراه اولین Execution (OPEN)،
 * به‌صورت اتمیک از طریق fn_create_position. این تنها مسیر مجاز برای ساخت
 * Position است؛ INSERT مستقیم روی strategy_positions مسدود شده.
 *
 * بدنه: {
 *   instrumentType: "STOCK" | "OPTION",
 *   underlyingSymbol, optionType?, strikePrice?, expiryDate?, optionSymbol?,
 *   contractSize?, direction: "LONG" | "SHORT", quantity, price, executedAt
 * }
 */
export async function POST(req: NextRequest) {
  const accessToken = req.headers.get("authorization")?.replace("Bearer ", "");
  if (!accessToken) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = await req.json();
  const {
    instrumentType,
    underlyingSymbol,
    optionType,
    strikePrice,
    expiryDate,
    optionSymbol,
    contractSize,
    direction,
    quantity,
    price,
    executedAt,
  } = body;

  if (!instrumentType || !underlyingSymbol || !direction || !quantity || !price || !executedAt) {
    return NextResponse.json({ error: "فیلدهای الزامی ناقص است" }, { status: 400 });
  }
  if (instrumentType === "OPTION" && (!optionType || !strikePrice || !expiryDate || !optionSymbol || !contractSize)) {
    return NextResponse.json({ error: "برای اختیار معامله، فیلدهای مخصوص آن الزامی است" }, { status: 400 });
  }

  const client = getUserScopedClient(accessToken);

  try {
    const positionId = await createPosition(client, {
      instrumentType,
      underlyingSymbol,
      optionType,
      strikePrice,
      expiryDate,
      optionSymbol,
      contractSize,
      direction,
      quantity,
      price,
      executedAt,
    });
    return NextResponse.json({ positionId });
  } catch (err) {
    return NextResponse.json({ error: (err as Error).message }, { status: 422 });
  }
}
