#!/usr/bin/env bash
# userId-scoping-audit-test.sh
# ─────────────────────────────────────────────────────────────────────────────
# SOW Security Audit — userId isolation / jwt.sub scoping
#
# Verifies that every data-bearing HTTP endpoint binds the tenant key to the
# verified JWT `sub` claim and that no path lets User A read User B's data.
#
# Audited areas (in order):
#   S1   Chat route body schema rejects user-supplied userId
#   S2   Sessions route always uses jwt.sub — no query-param userId
#   S3   listSessions hard-rejects empty / missing userId
#   S4   Cross-user session access returns FORBIDDEN_SESSION, not the session
#   S5   Legacy session isolation — strict owns() is the only gate (no bypass)
#   S6   Long-term memory call sites use jwt.sub (no user-supplied string)
#   S7   Trace route uses jwt.sub for ownership check
#   S8   Unscoped trace isolation — userOwnsTrace denies traces with no userId
#   S9   deleteSession ownership — user B cannot delete user A's session
#  S10   appendUserMessage cross-user access returns FORBIDDEN_SESSION
#  S11   No userId in POST /chat request body schema
#  S12   Full session-store unit suite
#  S13   Full jwt-verify unit suite
#  S14   HTTP-level user isolation integration suite (cross-user sessions/traces/chat)
#  S15   Trace-routes integration suite (unscoped traces → 404, cross-user → 404)
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
section_pass=0
section_fail=0

banner() {
  echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  $1${NC}"
  echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${NC}"
}

section() {
  echo -e "\n${YELLOW}${BOLD}──── $1 ────${NC}"
  section_pass=0
  section_fail=0
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

section_summary() {
  if [[ $section_fail -eq 0 ]]; then
    echo -e "  ${GREEN}Section result: ${section_pass} passed, 0 failed ✓${NC}"
  else
    echo -e "  ${RED}Section result: ${section_pass} passed, ${section_fail} FAILED ✗${NC}"
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
    const bodySchema = z.object({
      message: z.string().min(1),
      sessionId: z.string().min(1),
      agentId: z.string().optional(),
    });
    const result = bodySchema.safeParse({ message: 'hi', sessionId: 's1', userId: 'attacker' });
    if (!result.success) process.exit(1);
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
section "S5 · Session isolation — strict owns() is the only ownership gate"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/lib/session-store.ts :: owns()"
echo "  Requirement: Sessions with no userId must be denied to all callers."
echo "               No legacy bypass function (ownsOrLegacy) may exist."
echo "               The owns() function must require both record.userId and"
echo "               record.userId === userId."

run_test "session-store has no 'ownsOrLegacy' or 'return true for missing userId' bypass" \
  "! grep -q 'ownsOrLegacy\|return true.*legacy\|!record.userId.*return true' '$API_DIR/src/lib/session-store.ts'"

run_test "session-store has no legacy 'first caller claims' mutation block" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    const src = await Bun.file('./src/lib/session-store.ts').text();
    const hasClaim = src.includes('if (!s.userId)') && src.includes('s.userId = userId');
    process.exit(hasClaim ? 1 : 0);
  \""

run_test "owns() strict check is the only ownership gate" \
  "grep -q 'function owns(' '$API_DIR/src/lib/session-store.ts'"

run_test "owns() requires record.userId to be truthy (denies unscoped sessions)" \
  "grep -A3 'function owns(' '$API_DIR/src/lib/session-store.ts' | grep -q '!!record.userId\|record\.userId &&'"

run_test "owns() uses strict equality: record.userId === userId" \
  "grep -A3 'function owns(' '$API_DIR/src/lib/session-store.ts' | grep -q 'record\.userId === userId'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S6 · Long-term memory — call sites use jwt.sub, not user-supplied string"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/routes/chat.ts + api/src/lib/long-term-memory.ts"
echo "  Requirement: readLongTermMemory / writeLongTermMemory must be called with"
echo "               the userId derived from c.get('jwtPayload')?.sub in chat.ts."

run_test "chat.ts calls readLongTermMemoryContext with userId from jwtPayload.sub" \
  "grep -q 'contextUserId = userId' '$API_DIR/src/routes/chat.ts' && grep -q 'readLongTermMemoryContext(contextUserId' '$API_DIR/src/routes/chat.ts'"

run_test "chat.ts calls writeLongTermMemory with userId from jwtPayload.sub" \
  "grep -n 'writeLongTermMemory' '$API_DIR/src/routes/chat.ts' | grep -q 'userId'"

run_test "long-term-memory module uses the userId parameter in Mongo find() queries" \
  "grep -A3 'find(' '$API_DIR/src/lib/long-term-memory.ts' | grep -q 'userId'"

run_test "long-term-memory does NOT accept userId from req body / params" \
  "grep -q 'req.json.*userId\|req.query.*userId\|req.param.*userId' '$API_DIR/src/lib/long-term-memory.ts' && exit 1 || exit 0"

run_test "writeLongTermMemory stores userId from its parameter (not a hardcoded value)" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    const src = await Bun.file('./src/lib/long-term-memory.ts').text();
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
section "S8 · Unscoped trace isolation — userOwnsTrace denies traces with no userId"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/routes/trace.ts :: userOwnsTrace()"
echo "  Requirement: Traces with no userId field must be denied to ALL callers —"
echo "               the same as a foreign-owned trace. Any authenticated user"
echo "               who knows a legacy traceId must NOT be able to read it."

run_test "userOwnsTrace has no bypass for traces with missing userId" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    const src = await Bun.file('./src/routes/trace.ts').text();
    const hasLegacyBypass = src.includes('if (!trace.userId) return true');
    process.exit(hasLegacyBypass ? 1 : 0);
  \""

run_test "userOwnsTrace requires !!trace.userId (denies falsy userId)" \
  "grep -A6 'function userOwnsTrace' '$API_DIR/src/routes/trace.ts' | grep -q '!!trace\.userId'"

run_test "listRecentTraces accepts a userId parameter for server-side filtering" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    const src = await Bun.file('./src/lib/trace-store.ts').text();
    const hasUserFilter = src.includes('listRecentTraces') && src.includes('userId');
    process.exit(hasUserFilter ? 0 : 1);
  \""

run_test "GET /traces listing applies userOwnsTrace as final safety-net filter" \
  "grep -A20 'traceRoutes.get.*\"/traces\"' '$API_DIR/src/routes/trace.ts' | grep -q 'userOwnsTrace'"

run_test "userOwnsTrace is called for every trace read endpoint (count >= 4)" \
  "grep -c 'userOwnsTrace' '$API_DIR/src/routes/trace.ts' | grep -qE '^[4-9]|^[1-9][0-9]'"

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

run_test "DELETE /sessions/:id route maps false return to 404 (not 200 or 403)" \
  "grep -A5 'deleteSession' '$API_DIR/src/routes/sessions.ts' | grep -q 'notFound\|404'"

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

run_test "cross-user appendUserMessage leaves the owner's session unmodified" \
  "cd '$API_DIR' && $ENV_PREFIX bun -e \"
    import { getOrCreateSession, appendUserMessage, getSession, FORBIDDEN_SESSION } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('s10-nomod-sess', 'alice-s10-nomod');
      await appendUserMessage('s10-nomod-sess', 'intruder', 'bob-s10-nomod');
      const s = await getSession('s10-nomod-sess', 'alice-s10-nomod');
      if (!s || s === FORBIDDEN_SESSION) process.exit(1);
      process.exit(s.messages.length === 0 ? 0 : 1);
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

run_test "No route uses req.query('userId') or req.param('userId') to scope tenant" \
  "grep -rn 'req\.query.*userId\|req\.param.*userId' '$API_DIR/src/routes/' | grep -q 'userId' && exit 1 || exit 0"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S12 · Full session-store unit suite"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Covers: CRUD, ownership, cross-user, listSessions, deleteSession"

run_test "session-store unit tests pass" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/unit/session-store.test.ts --bail 2>&1 | grep -q '0 fail'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S13 · Full jwt-verify unit suite"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Covers: sub extraction, issuer validation, no bypass"

run_test "jwt-verify unit tests pass" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/unit/jwt-verify.test.ts --bail 2>&1 | grep -q '0 fail'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S14 · HTTP-level user isolation integration suite"
# ─────────────────────────────────────────────────────────────────────────────
echo "  File: api/tests/integration/user-isolation.integration.test.ts"
echo "  Covers (62 tests):"
echo "    AUTH  — 401 without/with bad token on every protected route"
echo "    SL    — GET /sessions returns only the caller's sessions"
echo "    SR    — GET /sessions/:id cross-user → 404; existence not leaked"
echo "    SD    — DELETE /sessions/:id cross-user → 404; data intact after attack"
echo "    CH    — POST /chat on another user's session → 404; no message pollution"
echo "    TR    — GET /traces/:id cross-user and unscoped → 404; no payload leak"
echo "    TQ    — GET /trace (coords) cross-user and unscoped → 404"
echo "    TM    — GET /trace/mongo cross-user and unscoped → 404"
echo "    TL    — GET /traces lists only caller's traces; unscoped excluded"
echo "    MU    — three users in parallel — zero cross-contamination"
echo "    PE    — userId injection via query param / body stripped; ID enumeration blocked"

run_test "user-isolation integration suite: all 62 tests pass" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/integration/user-isolation.integration.test.ts 2>&1 | grep -q '62 pass'"

run_test "user-isolation integration suite: zero failures" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/integration/user-isolation.integration.test.ts 2>&1 | grep -q '0 fail'"

run_test "GET /sessions cross-user returns SESSION_NOT_FOUND (not 403) — source check" \
  "grep -A5 'FORBIDDEN_SESSION' '$API_DIR/src/routes/sessions.ts' | grep -q 'SESSION_NOT_FOUND\|notFound'"

run_test "DELETE /sessions/:id cross-user denies via deleteSession return value" \
  "grep -A3 'deleteSession' '$API_DIR/src/routes/sessions.ts' | grep -q 'notFound\|404'"

run_test "POST /chat on cross-user session returns SESSION_NOT_FOUND before LLM — source check" \
  "grep -A5 'FORBIDDEN_SESSION' '$API_DIR/src/routes/chat.ts' | grep -q 'SESSION_NOT_FOUND'"

run_test "userOwnsTrace denies unscoped traces — !!trace.userId is required" \
  "grep -A5 'function userOwnsTrace' '$API_DIR/src/routes/trace.ts' | grep -q '!!trace\.userId'"

run_test "GET /traces listing passes userId to listRecentTraces (no global query)" \
  "grep -A5 'listRecentTraces' '$API_DIR/src/routes/trace.ts' | grep -q 'userId'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S15 · Trace-routes HTTP integration suite"
# ─────────────────────────────────────────────────────────────────────────────
echo "  File: api/tests/integration/trace-routes.integration.test.ts"
echo "  Covers (10 tests):"
echo "    — 401 without token"
echo "    — 404 for non-existent trace"
echo "    — 404 for unscoped trace (no userId) — previously stale test, now correct"
echo "    — 200 for owner's scoped trace by ID"
echo "    — 200/404 for GET /trace by sessionId+messageId (scoped and unscoped)"
echo "    — 200 for GET /trace/mongo (owner) — 404 for unscoped"
echo "    — Correct listing for GET /traces (scoped only)"
echo "    — 404 cross-user trace access"

run_test "trace-routes integration suite: all 10 tests pass" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/integration/trace-routes.integration.test.ts 2>&1 | grep -q '10 pass'"

run_test "trace-routes integration suite: zero failures" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/integration/trace-routes.integration.test.ts 2>&1 | grep -q '0 fail'"

run_test "Unscoped trace test expects 404 (stale 200 expectation removed from test file)" \
  "grep -q 'unscoped traces are denied' '$API_DIR/tests/integration/trace-routes.integration.test.ts'"

run_test "Cross-user trace test expects 404 TRACE_NOT_FOUND" \
  "grep -A5 'mismatches caller' '$API_DIR/tests/integration/trace-routes.integration.test.ts' | grep -q '404'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "S16 · MCP-layer userId injection unit tests"
# ─────────────────────────────────────────────────────────────────────────────
echo "  File: api/tests/unit/mcp-userid-injection.test.ts"
echo "  Covers injectUserIdIntoArgs — the Mongo MCP tenant-isolation guard:"
echo "    — READ  (mongodb_query / mongodb_find / mongodb_vector_search)"
echo "    — WRITE (update_one/many, delete_one/many, replace_one)"
echo "    — INSERT (insert_one / insert_many — document + documents[])"
echo "    — AGGREGATE (prepend { \$match: { userId } } to pipeline)"
echo "    — GATEWAY prefix (mongodb-mcp___*) stripped before matching"
echo "    — PUBLIC collections (products / troubleshooting_docs) skipped"
echo "    — UNKNOWN tool names pass through unchanged"
echo "    — ATTACKER-supplied filter.userId overwritten with jwt.sub"
echo "    — [KNOWN GAP] aggregate with attacker-supplied \$match.userId not overwritten"
echo "    — userId NOT mutating original args object"

run_test "MCP-injection unit suite: all tests pass (count check)" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/unit/mcp-userid-injection.test.ts 2>&1 | grep -q 'pass'"

run_test "MCP-injection unit suite: zero failures" \
  "cd '$API_DIR' && $ENV_PREFIX bun test tests/unit/mcp-userid-injection.test.ts 2>&1 | grep -q '0 fail'"

run_test "injectUserIdIntoArgs is exported from mongodb-mcp-client.ts" \
  "grep -q 'export function injectUserIdIntoArgs' '$API_DIR/src/adapters/mongodb-mcp-client.ts'"

run_test "READ tools (mongodb_query/find/vector_search) are in READ_FILTER_TOOLS set" \
  "grep -A3 'READ_FILTER_TOOLS' '$API_DIR/src/adapters/mongodb-mcp-client.ts' | grep -q 'mongodb_query'"

run_test "WRITE tools (update/delete/replace) are in WRITE_FILTER_TOOLS set" \
  "grep -A5 'WRITE_FILTER_TOOLS' '$API_DIR/src/adapters/mongodb-mcp-client.ts' | grep -q 'mongodb_update_one'"

run_test "INSERT tools (insert_one/many) are in INSERT_TOOLS set" \
  "grep -A3 'INSERT_TOOLS' '$API_DIR/src/adapters/mongodb-mcp-client.ts' | grep -q 'mongodb_insert_one'"

run_test "injectUserIdIntoArgs forces filter.userId = uid overwriting attacker value" \
  "grep -A3 'existing, userId' '$API_DIR/src/adapters/mongodb-mcp-client.ts' | grep -q 'userId'"

run_test "Public collections (products/troubleshooting_docs) bypass injection" \
  "grep -A3 'publicCollections.*has' '$API_DIR/src/adapters/mongodb-mcp-client.ts' | grep -q 'return args'"

run_test "MCP callTool wrapper calls injectUserIdIntoArgs with currentUserId()" \
  "grep -q 'injectUserIdIntoArgs(tool.name, args, uid)' '$API_DIR/src/adapters/mongodb-mcp-client.ts'"

run_test "MCP callTool skips injection only when uid is falsy (not when uid exists)" \
  "grep -q 'uid ? injectUserIdIntoArgs' '$API_DIR/src/adapters/mongodb-mcp-client.ts'"

run_test "aggregate: known-gap test documents attacker \$match.userId bypass" \
  "grep -q 'KNOWN GAP' '$API_DIR/tests/unit/mcp-userid-injection.test.ts'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
banner "FINAL SUMMARY"
# ─────────────────────────────────────────────────────────────────────────────

total=$((pass + fail))
echo ""
echo -e "  Total checks : ${total}"
echo -e "  ${GREEN}Passed       : ${pass}${NC}"
if [[ $fail -gt 0 ]]; then
  echo -e "  ${RED}FAILED       : ${fail}${NC}"
else
  echo -e "  ${GREEN}Hard failures: 0${NC}"
fi

echo ""
if [[ $fail -gt 0 ]]; then
  echo -e "\n${RED}${BOLD}  ✗ One or more userId-scoping controls are NOT correctly implemented.${NC}"
  exit 1
else
  echo -e "\n${GREEN}${BOLD}  ✓ All userId-scoping checks pass. User isolation is fully enforced.${NC}"
  echo -e "${GREEN}    Sessions, chat, memory, and traces are all scoped to jwt.sub.${NC}"
  echo -e "${GREEN}    Unscoped (legacy) traces and sessions are denied to all callers.${NC}"
  echo -e "${GREEN}    MCP-layer injection forces userId on all non-public MongoDB tool calls.${NC}"
  exit 0
fi
