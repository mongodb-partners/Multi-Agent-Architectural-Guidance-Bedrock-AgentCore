/**
 * Token phase metadata for the multi-specialist orchestrator.
 *
 * - `"specialist"` — text is from one specialist's draft. The UI renders
 *   it as an attributed live block but does NOT accumulate it into the
 *   persisted assistant message.
 * - `"synthesis"` — text is from the orchestrator's synthesizer agent.
 *   The UI accumulates this into the persisted assistant message.
 *
 * Tokens without `phase` (legacy / single-specialist fast path) are
 * accumulated and persisted as today, for backwards compatibility.
 */
export type TokenPhase = "specialist" | "synthesis";

export type ChatStreamPart =
  | {
      type: "token";
      text: string;
      /** Multi-specialist phase metadata (optional for backward compat). */
      phase?: TokenPhase;
      /** Specialist agent id when `phase === "specialist"`. */
      specialistId?: string;
      /** Specialist display name when `phase === "specialist"`. */
      specialistName?: string;
      /** 0-indexed rank in the classifier-ordered specialist list. */
      rank?: number;
    }
  | { type: "skill_loaded"; skillName: string }
  | { type: "tool_call"; tool: string; status: string }
  | { type: "agent_active"; agentId: string; agentName: string }
  | { type: "handoff"; from: string; to: string; label: string }
  /** Terminal failure for this turn; route maps to SSE `error` + `done` with `error`. */
  | { type: "stream_error"; code: string; message: string };
