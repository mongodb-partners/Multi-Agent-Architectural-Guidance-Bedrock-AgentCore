export type ChatStreamPart =
  | { type: "token"; text: string }
  | { type: "skill_loaded"; skillName: string }
  | { type: "tool_call"; tool: string; status: string }
  | { type: "agent_active"; agentId: string; agentName: string }
  | { type: "handoff"; from: string; to: string; label: string }
  /** Terminal failure for this turn; route maps to SSE `error` + `done` with `error`. */
  | { type: "stream_error"; code: string; message: string };
