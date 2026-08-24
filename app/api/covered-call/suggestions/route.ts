import { NextRequest, NextResponse } from "next/server";
import { getUserScopedClient } from "../../../../lib/supabase/client";

// توجه: runSuggestionEngine به lib/strategy/covered-call/suggestionEngine.ts
// منتقل شد. در Next.js App Router، فایل‌های route.ts فقط اجازهٔ Export متدهای
// HTTP (GET/POST/...) را دارند؛ هر Export دیگری خطای Build می‌دهد.
// وقتی Adapter واقعی Market API (Phase 2) آماده شد، یک POST اینجا اضافه
// می‌شود که فقط runSuggestionEngine را با fetchOptionChain واقعی صدا می‌زند.

/**
 * GET /api/covered-call/suggestions
 * پیشنهادهای فعال Covered Call را برمی‌گرداند (RLS خودش فقط ACTIVE و
 * Authenticated بودن را چک می‌کند؛ فیلتر بیشتر بر اساس Subscription در
 * لایهٔ بالاتر Application اعمال می‌شود، نه اینجا).
 */
export async function GET(req: NextRequest) {
  const accessToken = req.headers.get("authorization")?.replace("Bearer ", "");
  if (!accessToken) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  const client = getUserScopedClient(accessToken);

  const { data, error } = await client
    .from("suggestions")
    .select("*, symbols(symbol_code, display_name), suggestion_risk_tiers(code, display_name)")
    .eq("status", "ACTIVE")
    .order("rank", { ascending: true });

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ suggestions: data });
}
