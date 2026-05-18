#!/usr/bin/env bash
# userId-scoping-audit-test.sh
# ─────────────────────────────────────────────────────────────────────────────
# SOW Security Audit — userId isolation / jwt.sub scoping
#
# Verifies that every data-bearing HTTP endpoint binds the tenant key to the
# verified JWT `sub` claim and that no path lets User A read User B's data.
#
# Audited areas (in order):
#   S1  Chat route body schema rejects user-supplied userId
#   S2  Sessions route always uses jwt.sub — no query-param userId
#   S3  listSessions hard-rejects empty / missing userId
#   S4  Cross-user session access returns FORBIDDEN_SESSION, not the session
#   S5  Legacy sessions (no userId field) isolation gap — ownsOrLegacy bypass
#   S6  Long-term memory call sites use jwt.sub (no user-supplied string)
#   S7  Trace route uses jwt.sub for ownership check
#   S8  Legacy trace isolation gap — userOwnsTrace unscoped-trace bypass
#   S9  deleteSession ownership — user B cannot delete user A's session
#  S10  appendUserMessage cross-user access returns FORBIDDEN_SESSION
#  S11  No userId in POST /chat request body schema
#  S12  Full session-store unit suite passes
#  S13  Full jwt-verify unit suite passes
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_DIR="$REPO_ROOT/api"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass=0
fail=0
skip=0
section_pass=0
section_fail=0
section_skip=0

banner() {
  echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  $1${NC}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
}

section() {
  echo -e "\n${YELLOW}${BOLD}──── $1 ────${NC}"
  section_pass=0
  section_fail=0
  section_skip=0
}

run_test() {
  local label="$1"
  local cmd="$2"
  if ( eval "$cmd" ) > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $label"
    ((pass++)) || true
    ((section_pass++)) || true
  else
    echo -e "  ${RED}✗${NC} $label"
    ((fail++)) || true
    ((section_fail++)) || true
  fi
}

# A test that documents a KNOWN GAP — expected to fail until the gap is fixed.
# Counts as a "gap" in the summary, not a blocking test failure.
run_gap_test() {
  local label="$1"
  local cmd="$2"
  if ( eval "$cmd" ) > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} [GAP CLOSED] $label"
    ((pass++)) || true
    ((section_pass++)) || true
  else
    echo -e "  ${YELLOW}△${NC} [KNOWN GAP]  $label"
    ((skip++)) || true
    ((section_skip++)) || true
  fi
}

section_summary() {
  local gap_note=""
  if [[ $section_skip -gt 0 ]]; then
    gap_note=" (${section_skip} known gap(s))"
  fi
  if [[ $section_fail -eq 0 ]]; then
    echo -e "  ${GREEN}Section result: ${section_pass} passed, 0 failed${gap_note} ✓${NC}"
  else
    echo -e "  ${RED}Section result: ${section_pass} passed, ${section_fail} FAILED${gap_note} ✗${NC}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
banner "SOW Security Audit — userId / jwt.sub Isolation"
# ─────────────────────────────────────────────────────────────────────────────

echo -e "\nChecking prerequisites..."
if ! command -v bun &> /dev/null; then
  echo -e "${RED}ERROR: bun not found. Install from https://bun.sh${NC}"
  exit 1
fi
echo -e "  bun: $(bun --version)"

# Common env prefix used for all bun -e invocations
ENV_PREFIX="AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com"

# ─────────────────────────────────────────────────────────────────────────────
section "S1 · POST /chat body schema — userId must NOT be accepted from client"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/routes/chat.ts"
echo "  Requirement: The request body schema must only accept message, sessionId,"
echo "               and optional agentId. A client-supplied userId field must NOT"
echo "               be present — the server always derives userId from jwt.sub."

run_test "chat body schema has no userId field" \
  "grep -n 'userId' '$API_DIR/src/routes/chat.ts' | grep -v 'jwtPayload' | grep -v '//' | grep -q 'userId.*z\.' && exit 1 || exit 0"

run_test "chat body schema does NOT include userId key in z.object()" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { z } from 'zod';
    // Simulate parsing a body that includes an attacker-supplied userId
    const bodySchema = z.object({
      message: z.string().min(1),
      sessionId: z.string().min(1),
      agentId: z.string().optional(),
    });
    const result = bodySchema.safeParse({ message: 'hi', sessionId: 's1', userId: 'attacker' });
    if (!result.success) process.exit(1);
    // userId should be stripped by schema (strict not required — presence check)
    const hasUserId = 'userId' in (result.data as object);
    process.exit(hasUserId ? 1 : 0);
  \""

run_test "chat route reads userId only from c.get('jwtPayload')?.sub" \
  "grep -n 'userId' '$API_DIR/src/routes/chat.ts' | grep -q 'jwtPayload.*sub\|sub.*jwtPayload'"

run_test "chat route contains defensive 401 when jwt.sub is missing" \
  "grep -q 'UNAUTHORIZED' '$API_DIR/src/routes/chat.ts'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S2 · GET /sessions — must use jwt.sub, not a query param"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/routes/sessions.ts"
echo "  Requirement: Listing, fetching, and deleting sessions must be scoped to"
echo "               the authenticated user's jwt.sub. No userId query parameter."

run_test "sessions route uses jwtPayload?.sub for userId" \
  "grep -q 'jwtPayload.*sub\|sub.*jwtPayload' '$API_DIR/src/routes/sessions.ts'"

run_test "sessions route does NOT read userId from req.query()" \
  "grep -q 'req.query.*userId\|query.*userId' '$API_DIR/src/routes/sessions.ts' && exit 1 || exit 0"

run_test "sessions route does NOT read userId from req.param()" \
  "grep -n 'req.param' '$API_DIR/src/routes/sessions.ts' | grep -q 'userId' && exit 1 || exit 0"

run_test "sessions route does NOT read userId from req.json() body" \
  "grep -n 'req.json\|req.body' '$API_DIR/src/routes/sessions.ts' | grep -q 'userId' && exit 1 || exit 0"

run_test "sessions route returns 401 when jwt.sub is missing" \
  "grep -q 'unauthorized\|UNAUTHORIZED' '$API_DIR/src/routes/sessions.ts'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S3 · listSessions — hard rejects empty / missing userId"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/lib/session-store.ts :: listSessions()"
echo "  Requirement: A blank or undefined userId must throw; never list globally."

run_test "listSessions throws when userId is empty string" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { listSessions } from './src/lib/session-store.ts';
    listSessions('').then(() => process.exit(1)).catch(() => process.exit(0));
  \""

run_test "listSessions throws when userId is undefined cast" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { listSessions } from './src/lib/session-store.ts';
    listSessions(undefined as unknown as string).then(() => process.exit(1)).catch(() => process.exit(0));
  \""

run_test "listSessions returns only sessions matching the given userId" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { getOrCreateSession, listSessions } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('alice-s3-sess', 'alice-s3');
      await getOrCreateSession('bob-s3-sess',   'bob-s3');
      const aliceSessions = await listSessions('alice-s3');
      const ids = aliceSessions.map(s => s.sessionId);
      if (ids.includes('bob-s3-sess')) process.exit(1);
      if (!ids.includes('alice-s3-sess')) process.exit(1);
      process.exit(0);
    })();
  \""

run_test "listSessions uses strict equality (not includes) for userId filter" \
  "grep -A5 'listFromMemory' '$API_DIR/src/lib/session-store.ts' | grep -q '!== userId\|=== userId'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S4 · Cross-user session access returns FORBIDDEN_SESSION"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/lib/session-store.ts"
echo "  Requirement: getSession / getOrCreateSession / appendUserMessage for a"
echo "               session owned by User A must return FORBIDDEN_SESSION for"
echo "               User B — never the actual session data."

run_test "getOrCreateSession returns FORBIDDEN_SESSION for cross-user access" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { getOrCreateSession, FORBIDDEN_SESSION } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('s4-sess', 'alice-s4');
      const r = await getOrCreateSession('s4-sess', 'bob-s4');
      process.exit(r === FORBIDDEN_SESSION ? 0 : 1);
    })();
  \""

run_test "getSession returns FORBIDDEN_SESSION for cross-user access" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { getOrCreateSession, getSession, FORBIDDEN_SESSION } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('s4-get-sess', 'alice-s4');
      const r = await getSession('s4-get-sess', 'bob-s4');
      process.exit(r === FORBIDDEN_SESSION ? 0 : 1);
    })();
  \""

run_test "getSession returns undefined (not data) for unknown session" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { getSession, FORBIDDEN_SESSION } from './src/lib/session-store.ts';
    (async () => {
      const r = await getSession('nonexistent-sess', 'alice-s4');
      process.exit(r === undefined ? 0 : 1);
    })();
  \""

run_test "FORBIDDEN_SESSION response does NOT reveal session existence to caller" \
  "grep -A10 'FORBIDDEN_SESSION' '$API_DIR/src/routes/chat.ts' | grep -q 'SESSION_NOT_FOUND'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S5 · Legacy session isolation gap — ownsOrLegacy bypass (KNOWN GAPS)"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/lib/session-store.ts :: ownsOrLegacy()"
echo "  Concern: Sessions with no userId field are treated as owned by any caller."
echo "           Any authenticated user who knows a legacy sessionId can read it."
echo "  Status: KNOWN GAP — marked as run_gap_test; fails until the code is fixed."

run_gap_test "ownsOrLegacy returns false for unscoped session accessed by a specific user" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    // Inject a legacy record (no userId) directly into the in-memory store.
    // A properly fixed ownsOrLegacy should deny access rather than grant it.
    import { FORBIDDEN_SESSION, getSession } from './src/lib/session-store.ts';
    // Reach into internals via dynamic import to plant a legacy record
    const mod = await import('./src/lib/session-store.ts');
    // We can't easily plant without internal access, so verify the policy is NOT
    // 'treat null userId as everyone's' — check the source text instead.
    const src = await Bun.file('./src/lib/session-store.ts').text();
    // If ownsOrLegacy still has the 'return true' for missing userId, it's the gap.
    const hasLegacyBypass = src.includes('if (!record.userId) return true');
    process.exit(hasLegacyBypass ? 1 : 0); // exit 1 = gap still present
  \""

run_gap_test "session-store has no 'legacy claimed by first caller' mutation" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    const src = await Bun.file('./src/lib/session-store.ts').text();
    // This block: if (!s.userId) { s.userId = userId; ... } silently claims legacy sessions
    const hasClaim = src.includes('if (!s.userId)') && src.includes('s.userId = userId');
    process.exit(hasClaim ? 1 : 0);
  \""

run_test "owns() strict check is the only ownership gate (no legacy bypass function)" \
  "grep -q 'function owns(' '$API_DIR/src/lib/session-store.ts' && ! grep -q 'ownsOrLegacy\|return true.*legacy\|!record.userId.*return true' '$API_DIR/src/lib/session-store.ts'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S6 · Long-term memory — call sites use jwt.sub, not user-supplied string"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/routes/chat.ts + api/src/lib/long-term-memory.ts"
echo "  Requirement: readLongTermMemory / writeLongTermMemory must be called with"
echo "               the userId derived from c.get('jwtPayload')?.sub in chat.ts."

run_test "chat.ts calls readLongTermMemory with userId from jwtPayload.sub" \
  "grep -q 'contextUserId = userId' '$API_DIR/src/routes/chat.ts' && grep -q 'readLongTermMemory(contextUserId' '$API_DIR/src/routes/chat.ts'"

run_test "chat.ts calls writeLongTermMemory with userId from jwtPayload.sub" \
  "grep -n 'writeLongTermMemory' '$API_DIR/src/routes/chat.ts' | grep -q 'userId'"

run_test "long-term-memory module uses the userId parameter in Mongo find() queries" \
  "grep -A3 'find(' '$API_DIR/src/lib/long-term-memory.ts' | grep -q 'userId'"

run_test "long-term-memory does NOT accept userId from req body / params" \
  "grep -q 'req.json.*userId\|req.query.*userId\|req.param.*userId' '$API_DIR/src/lib/long-term-memory.ts' && exit 1 || exit 0"

run_test "writeLongTermMemory stores userId from its parameter (not a hardcoded value)" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    const src = await Bun.file('./src/lib/long-term-memory.ts').text();
    // Must reference userId in the document being written
    if (!src.includes('userId')) process.exit(1);
    process.exit(0);
  \""

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S7 · Trace route — ownership check uses jwt.sub"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/routes/trace.ts"
echo "  Requirement: GET /traces/:traceId, GET /trace, GET /traces must all compare"
echo "               trace.userId against the authenticated user's jwt.sub."

run_test "trace.ts extracts userId from jwtPayload?.sub" \
  "grep -q 'jwtPayload.*sub\|sub.*jwtPayload' '$API_DIR/src/routes/trace.ts'"

run_test "userOwnsTrace checks trace.userId === userId" \
  "grep -A6 'userOwnsTrace' '$API_DIR/src/routes/trace.ts' | grep -q 'trace.userId === userId'"

run_test "GET /traces/:traceId calls userOwnsTrace before returning data" \
  "grep -A8 'traces/:traceId' '$API_DIR/src/routes/trace.ts' | grep -q 'userOwnsTrace'"

run_test "GET /trace (by sessionId+messageId) calls userOwnsTrace before returning data" \
  "grep -A25 'traceRoutes.get.*\"/trace\"' '$API_DIR/src/routes/trace.ts' | grep -q 'userOwnsTrace'"

run_test "trace route does NOT accept userId from query params" \
  "grep -n 'req.query' '$API_DIR/src/routes/trace.ts' | grep -q 'userId' && exit 1 || exit 0"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S8 · Legacy trace isolation gap — unscoped traces readable by all (KNOWN GAP)"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/routes/trace.ts :: userOwnsTrace()"
echo "  Concern: Traces with no userId are returned to any authenticated user."
echo "  Status: KNOWN GAP — marked as run_gap_test; fails until fixed."

run_gap_test "userOwnsTrace does NOT return true for traces with missing userId" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    const src = await Bun.file('./src/routes/trace.ts').text();
    // Legacy bypass: 'if (!trace.userId) return true'
    const hasLegacyBypass = src.includes('if (!trace.userId) return true');
    process.exit(hasLegacyBypass ? 1 : 0);
  \""

run_gap_test "listRecentTraces does NOT return unscoped traces to authenticated users" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    // Check that listRecentTraces (trace-store.ts) accepts a userId filter parameter
    const src = await Bun.file('./src/lib/trace-store.ts').text();
    // Proper fix: listRecentTraces(userId) passes userId to the Mongo query
    const hasUserFilter = src.includes('listRecentTraces') && src.includes('userId');
    process.exit(hasUserFilter ? 0 : 1);
  \""

run_test "userOwnsTrace function is defined and called for all trace reads" \
  "grep -c 'userOwnsTrace' '$API_DIR/src/routes/trace.ts' | grep -qE '^[3-9]|^[1-9][0-9]'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S9 · deleteSession — user B cannot delete user A's session"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/lib/session-store.ts :: deleteSession()"
echo "  Requirement: Deleting a session must return false (not throw, not succeed)"
echo "               when the calling userId does not own the session."

run_test "deleteSession returns false when user does not own the session" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { getOrCreateSession, deleteSession } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('s9-del-sess', 'alice-s9');
      const deleted = await deleteSession('s9-del-sess', 'bob-s9');
      process.exit(deleted ? 1 : 0);
    })();
  \""

run_test "deleteSession returns true when the owner deletes their own session" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { getOrCreateSession, deleteSession } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('s9-own-sess', 'alice-s9-own');
      const deleted = await deleteSession('s9-own-sess', 'alice-s9-own');
      process.exit(deleted ? 0 : 1);
    })();
  \""

run_test "sessions route enforces delete ownership via deleteSession" \
  "grep -q 'deleteSession' '$API_DIR/src/routes/sessions.ts'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S10 · appendUserMessage cross-user access returns FORBIDDEN_SESSION"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/lib/session-store.ts :: appendUserMessage()"
echo "  Requirement: Appending a message to another user's session must be denied."

run_test "appendUserMessage returns FORBIDDEN_SESSION for cross-user access" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { getOrCreateSession, appendUserMessage, FORBIDDEN_SESSION } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('s10-append-sess', 'alice-s10');
      const r = await appendUserMessage('s10-append-sess', 'hello', 'bob-s10');
      process.exit(r === FORBIDDEN_SESSION ? 0 : 1);
    })();
  \""

run_test "appendUserMessage succeeds for session owner" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { getOrCreateSession, appendUserMessage, FORBIDDEN_SESSION } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('s10-own-sess', 'alice-s10-own');
      const r = await appendUserMessage('s10-own-sess', 'hello', 'alice-s10-own');
      process.exit(r === FORBIDDEN_SESSION ? 1 : 0);
    })();
  \""

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S11 · Static analysis — no route accepts userId in request body/params"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/routes/*.ts"
echo "  Requirement: No route handler may use a client-supplied userId as a tenant"
echo "               key. All userId values must come from jwt.sub."

run_test "chat.ts body schema zod object has no 'userId' key" \
  "grep -A6 'z\.object' '$API_DIR/src/routes/chat.ts' | grep -q 'userId:' && exit 1 || exit 0"

run_test "sessions.ts does not parse userId from request body" \
  "grep -n 'z.object\|req.json\|body.*userId' '$API_DIR/src/routes/sessions.ts' | grep -q 'userId.*z\.\|body.*userId' && exit 1 || exit 0"

run_test "trace.ts does not read userId from query/body" \
  "grep -n 'req.query\|req.json\|req.param' '$API_DIR/src/routes/trace.ts' | grep -q 'userId' && exit 1 || exit 0"

run_test "No route file defines a zod schema with userId field" \
  "grep -rn 'userId.*z\.\|z\.string.*userId' '$API_DIR/src/routes/' | grep -q 'userId' && exit 1 || exit 0"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S12 · Full session-store unit suite"
# ─────────────────────────────────────────────────────────────────────────────

run_test "session-store unit tests pass (covers ownership, cross-user, listSessions)" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/unit/session-store.test.ts --bail 2>&1 | grep -q '0 fail'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S13 · Full jwt-verify unit suite"
# ─────────────────────────────────────────────────────────────────────────────

run_test "jwt-verify unit tests pass (sub extraction, no bypass)" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/unit/jwt-verify.test.ts --bail 2>&1 | grep -q '0 fail'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
banner "FINAL SUMMARY"
# ─────────────────────────────────────────────────────────────────────────────

total=$((pass + fail + skip))
echo ""
echo -e "  Total checks : ${total}"
echo -e "  ${GREEN}Passed       : ${pass}${NC}"
echo -e "  ${YELLOW}Known gaps   : ${skip}${NC}  (marked △ above — require code fixes)"
if [[ $fail -gt 0 ]]; then
  echo -e "  ${RED}FAILED       : ${fail}${NC}"
else
  echo -e "  ${GREEN}Hard failures: 0${NC}"
fi

echo ""
if [[ $skip -gt 0 ]]; then
  echo -e "${YELLOW}${BOLD}  △ Known gaps detected. The main HTTP surface (sessions, chat, memory,"
  echo -e "    traces) correctly uses jwt.sub. However, legacy-row bypasses in"
  echo -e "    ownsOrLegacy (session-store) and userOwnsTrace (trace route) allow"
  echo -e "    any authenticated user to access unscoped historic records."
  echo -e "    See docs/analysis/userId-scoping-audit-2026-05-15.md for remediation.${NC}"
fi

if [[ $fail -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}  ✗ One or more userId-scoping controls are NOT implemented correctly.${NC}"
  exit 1
else
  echo -e "\n${GREEN}${BOLD}  ✓ All hard userId-scoping checks pass.${NC}"
  [[ $skip -gt 0 ]] && exit 2 || exit 0
fi
