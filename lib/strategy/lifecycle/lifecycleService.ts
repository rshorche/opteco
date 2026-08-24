import { SupabaseClient } from "@supabase/supabase-js";
import { TransitionLegActionInput, TransitionType } from "../../supabase/types";

export interface InitialEntryLeg {
  position_id: string;
  role_code: string;
}

/**
 * ساخت یک Position جدید — تنها مسیر مجاز، چون INSERT مستقیم روی
 * strategy_positions از authenticated گرفته شده (بعد از Hardening).
 * Position و اولین Execution (OPEN) در یک RPC اتمیک ساخته می‌شوند؛ در سطح
 * DB هم یک Constraint Trigger مستقل تضمین می‌کند این الزام هرگز دور زده نشود.
 */
export async function createPosition(
  client: SupabaseClient,
  params: {
    instrumentType: "STOCK" | "OPTION";
    underlyingSymbol: string;
    optionType?: "CALL" | "PUT";
    strikePrice?: number;
    expiryDate?: string;
    optionSymbol?: string;
    contractSize?: number;
    direction: "LONG" | "SHORT";
    quantity: number;
    price: number;
    executedAt: string;
  }
): Promise<string> {
  const { data, error } = await client.rpc("fn_create_position", {
    p_instrument_type: params.instrumentType,
    p_underlying_symbol: params.underlyingSymbol,
    p_option_type: params.optionType ?? null,
    p_strike_price: params.strikePrice ?? null,
    p_expiry_date: params.expiryDate ?? null,
    p_option_symbol: params.optionSymbol ?? null,
    p_contract_size: params.contractSize ?? null,
    p_direction: params.direction,
    p_quantity: params.quantity,
    p_price: params.price,
    p_executed_at: params.executedAt,
  });

  if (error) throw new Error(`createPosition failed: ${error.message}`);
  return data as string;
}

export async function recordInitialEntry(
  client: SupabaseClient,
  params: {
    strategyDefinitionId: string;
    underlyingSymbol: string;
    entrySource: "SUGGESTED" | "MANUAL";
    entrySuggestionId: string | null;
    legs: InitialEntryLeg[];
  }
): Promise<{ instanceId: string; cycleId: string }> {
  // توجه: شناسهٔ کاربر دیگر از کلاینت گرفته نمی‌شود — RPC آن را مستقیماً از
  // auth.uid() (یعنی JWT خودِ درخواست) می‌خواند تا امکان جعل هویت از بین برود.
  const { data, error } = await client.rpc("fn_record_initial_entry", {
    p_strategy_definition_id: params.strategyDefinitionId,
    p_underlying_symbol: params.underlyingSymbol,
    p_entry_source: params.entrySource,
    p_entry_suggestion_id: params.entrySuggestionId,
    p_legs: params.legs,
  });

  if (error) throw new Error(`recordInitialEntry failed: ${error.message}`);
  const row = Array.isArray(data) ? data[0] : data;
  return { instanceId: row.instance_id, cycleId: row.cycle_id };
}

export async function recordTransition(
  client: SupabaseClient,
  params: {
    instanceId: string;
    fromCycleId: string;
    toStrategyDefinitionId: string | null; // null = Transition پایانی
    transitionType: TransitionType;
    reason: Record<string, unknown>;
    triggeredBy: "SYSTEM_RECOMMENDATION" | "USER_MANUAL";
    actions: TransitionLegActionInput[];
  }
): Promise<{ transitionId: string; toCycleId: string | null; instanceStatus: "ACTIVE" | "CLOSED" }> {
  const { data, error } = await client.rpc("fn_record_transition", {
    p_instance_id: params.instanceId,
    p_from_cycle_id: params.fromCycleId,
    p_to_definition_id: params.toStrategyDefinitionId,
    p_transition_type: params.transitionType,
    p_reason: params.reason,
    p_triggered_by: params.triggeredBy,
    p_actions: params.actions.map((a) => ({
      position_id: a.position_id,
      action: a.action,
      role_before_code: a.role_before_code ?? null,
      role_after_code: a.role_after_code ?? null,
      detail: a.detail ?? {},
    })),
    // p_new_cycle_legs عمداً حذف شد: Legهای Cycle جدید کاملاً از روی
    // action های CARRIED/OPENED مشتق می‌شوند؛ نگه‌داشتن یک پارامتر جدا برای
    // همان داده، ریسک ناهم‌خوانی بدون هیچ سود عملی داشت.
  });

  if (error) throw new Error(`recordTransition failed: ${error.message}`);
  const row = Array.isArray(data) ? data[0] : data;
  return {
    transitionId: row.transition_id,
    toCycleId: row.to_cycle_id,
    instanceStatus: row.instance_status,
  };
}

/**
 * ثبت یک اجرای واقعی (خرید/فروش/بستن) روی یک Position — منبع حقیقت
 * position_executions است؛ strategy_positions خودکار (با Trigger پایگاه‌داده)
 * به‌روزرسانی می‌شود.
 */
export async function recordExecution(
  client: SupabaseClient,
  params: {
    positionId: string;
    executionType: "INCREASE" | "DECREASE" | "CLOSE"; // OPEN دیگر اینجا مجاز نیست
    quantity: number;
    price: number;
    executedAt: string;
    closeReason?: "BOUGHT_BACK" | "EXERCISED" | "EXPIRED" | "SOLD" | "TRANSFERRED";
    relatedTransitionId?: string;
    notes?: string;
  }
): Promise<void> {
  // اولین Execution (OPEN) هر Position فقط از طریق createPosition ساخته
  // می‌شود، چون باید در همان تراکنشی باشد که خودِ Position را می‌سازد —
  // در غیر این صورت Constraint Trigger سطح DB کل تراکنش را Rollback می‌کند.
  const { error } = await client.from("position_executions").insert({
    position_id: params.positionId,
    execution_type: params.executionType,
    quantity: params.quantity,
    price: params.price,
    executed_at: params.executedAt,
    close_reason: params.closeReason ?? null,
    related_transition_id: params.relatedTransitionId ?? null,
    notes: params.notes ?? null,
  });

  if (error) throw new Error(`recordExecution failed: ${error.message}`);
}
