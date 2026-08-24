// نگاشت دستی و حداقلی جداول هستهٔ Opteco که این Vertical Slice به آن‌ها نیاز دارد.
// در پروژهٔ واقعی این فایل باید با `supabase gen types typescript` جایگزین شود.

export type InstrumentType = "STOCK" | "OPTION";
export type OptionType = "CALL" | "PUT";
export type Direction = "LONG" | "SHORT";
export type PositionStatus = "OPEN" | "CLOSED";
export type ExecutionType = "OPEN" | "INCREASE" | "DECREASE" | "CLOSE";
export type CloseReason =
  | "BOUGHT_BACK"
  | "EXERCISED"
  | "EXPIRED"
  | "SOLD"
  | "TRANSFERRED";

export type OriginType = "INITIAL_ENTRY" | "TRANSITION";
export type EntrySource = "SUGGESTED" | "MANUAL";
export type CycleStatus = "OPEN" | "CLOSED";
export type InstanceStatus = "ACTIVE" | "CLOSED";

export type TransitionType =
  | "ROLL"
  | "OFFSET"
  | "STRATEGY_TYPE_CHANGE"
  | "EXERCISE"
  | "EXPIRE"
  | "PARTIAL_CLOSE"
  | "FINAL_CLOSE";

export type TransitionActionType =
  | "CLOSED"
  | "CARRIED"
  | "OPENED"
  | "RELEASED"
  | "MODIFIED";

export interface StrategyPosition {
  id: string;
  user_id: string;
  instrument_type: InstrumentType;
  underlying_symbol: string;
  option_type: OptionType | null;
  strike_price: number | null;
  expiry_date: string | null;
  option_symbol: string | null;
  contract_size: number | null;
  direction: Direction;
  quantity: number;
  entry_price: number;
  entry_date: string;
  status: PositionStatus;
  close_reason: CloseReason | null;
  close_price: number | null;
  close_date: string | null;
}

export interface StrategyInstance {
  id: string;
  user_id: string;
  status: InstanceStatus;
  underlying_symbol: string;
  started_at: string;
  closed_at: string | null;
}

export interface StrategyCycle {
  id: string;
  strategy_instance_id: string;
  strategy_definition_id: string;
  status: CycleStatus;
  origin_type: OriginType;
  origin_transition_id: string | null;
  entry_source: EntrySource;
  entry_suggestion_id: string | null;
}

export interface StrategyTransition {
  id: string;
  strategy_instance_id: string;
  from_cycle_id: string;
  to_cycle_id: string | null;
  transition_type: TransitionType;
  reason: Record<string, unknown> | null;
  triggered_by: "SYSTEM_RECOMMENDATION" | "USER_MANUAL";
  user_confirmed: boolean;
}

/** ورودی هر Leg متأثر از یک Transition — دقیقاً معادل strategy_transition_actions */
export interface TransitionLegActionInput {
  position_id: string;
  action: TransitionActionType;
  role_before_code?: string; // کد strategy_leg_roles، نه UUID — سرویس آن را Resolve می‌کند
  role_after_code?: string;
  detail?: Record<string, unknown>;
}

export interface SuggestionCandidate {
  symbol_code: string;
  risk_tier_code: string;
  option_symbol: string;
  strike: number;
  expiry: string;
  option_type: OptionType;
  contract_size: number;
  spot_price: number;
  premium: number;
  bid: number;
  ask: number;
  volume: number;
  value_traded: number;
  monthly_yield: number;
  break_even: number;
  max_profit: number;
  max_loss: number;
  safety_margin_pct: number;
}
