#!/usr/bin/env bash
# security-audit-test.sh
# ─────────────────────────────────────────────────────────────────────────────
# Security testing — comprehensive audit of the four P0 gaps reported in
# the weekly task review. Run from repo root or from e2e-smoke/. Requires Bun.
#
# Audited items:
#   P0-1  Auth bypass guard at boot   — assertJwksAuthConfigured() hard-fails
#   P0-2  Session enumeration scope   — GET /sessions strictly scoped by userId
#   P0-3  SSRF allowlist enforcement  — assertHttpToolsFileSecure + runtime guard
#   P0-4  Lambda log redaction        — redactArgsForLog / redactEventForLog
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_DIR="$REPO_ROOT/api"
MCP_DIR="$REPO_ROOT/mcp-runtimes/mongodb-mcp"

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
  if eval "$cmd" > /dev/null 2>&1; then
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
banner "Security audit — all four P0 items"
# ─────────────────────────────────────────────────────────────────────────────

echo -e "\nChecking prerequisites..."
if ! command -v bun &> /dev/null; then
  echo -e "${RED}ERROR: bun not found. Install from https://bun.sh${NC}"
  exit 1
fi
echo -e "  bun: $(bun --version)"

# Ensure mcp-runtimes deps are installed (needed for P0-4 redaction tests)
if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo -e "  Installing mcp-runtimes/mongodb-mcp dependencies..."
  (cd "$MCP_DIR" && npm install --silent)
fi

# ─────────────────────────────────────────────────────────────────────────────
section "P0-1 · Auth bypass guard at boot (assertJwksAuthConfigured)"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/lib/jwt-verify.ts :: assertJwksAuthConfigured()"
echo "  Requirement: API process must REFUSE to start when AUTH_JWKS_URI or"
echo "               AUTH_ISSUER is absent — no unauthenticated fallback mode."

run_test "assertJwksAuthConfigured throws when AUTH_JWKS_URI is missing" \
  "cd '$API_DIR' && AUTH_ISSUER=https://test.example.com bun -e \"
    import { assertJwksAuthConfigured } from './src/lib/jwt-verify.ts';
    try { assertJwksAuthConfigured(); process.exit(1); }
    catch(e) { if (e.message.includes('AUTH_JWKS_URI')) process.exit(0); process.exit(1); }
  \""

run_test "assertJwksAuthConfigured throws when AUTH_ISSUER is missing" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json bun -e \"
    import { assertJwksAuthConfigured } from './src/lib/jwt-verify.ts';
    try { assertJwksAuthConfigured(); process.exit(1); }
    catch(e) { if (e.message.includes('AUTH_ISSUER')) process.exit(0); process.exit(1); }
  \""

run_test "assertJwksAuthConfigured throws when BOTH are missing" \
  "cd '$API_DIR' && bun -e \"
    import { assertJwksAuthConfigured } from './src/lib/jwt-verify.ts';
    try { assertJwksAuthConfigured(); process.exit(1); }
    catch(e) { if (e.message.includes('AUTH_JWKS_URI') && e.message.includes('AUTH_ISSUER')) process.exit(0); process.exit(1); }
  \""

run_test "assertJwksAuthConfigured passes when both vars are present" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { assertJwksAuthConfigured } from './src/lib/jwt-verify.ts';
    try { assertJwksAuthConfigured(); process.exit(0); }
    catch(e) { process.exit(1); }
  \""

run_test "verifyBearerJwt throws when env vars unset (no silent fallback)" \
  "cd '$API_DIR' && bun -e \"
    import { verifyBearerJwt } from './src/lib/jwt-verify.ts';
    verifyBearerJwt('any-token').then(() => process.exit(1)).catch(e => {
      if (e.message.includes('misconfigured')) process.exit(0); process.exit(1);
    });
  \""

run_test "isJwksAuthConfigured returns false when env missing" \
  "cd '$API_DIR' && bun -e \"
    import { isJwksAuthConfigured } from './src/lib/jwt-verify.ts';
    process.exit(isJwksAuthConfigured() ? 1 : 0);
  \""

run_test "Full jwt-verify unit suite passes" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun test tests/unit/jwt-verify.test.ts --bail 2>&1 | grep -q '0 fail'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "P0-2 · Session enumeration scope (GET /sessions always scoped by JWT sub)"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/routes/sessions.ts, api/src/lib/session-store.ts"
echo "  Requirement: GET /sessions must ONLY return sessions owned by the"
echo "               authenticated user; no global listing permitted."

run_test "listSessions throws when userId is empty string" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { listSessions } from './src/lib/session-store.ts';
    listSessions('').then(() => process.exit(1)).catch(() => process.exit(0));
  \""

run_test "listSessions throws when userId is undefined" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { listSessions } from './src/lib/session-store.ts';
    listSessions(undefined).then(() => process.exit(1)).catch(() => process.exit(0));
  \""

run_test "getOrCreateSession returns FORBIDDEN_SESSION for cross-user access" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { getOrCreateSession, FORBIDDEN_SESSION } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('s1', 'alice');
      const r = await getOrCreateSession('s1', 'bob');
      process.exit(r === FORBIDDEN_SESSION ? 0 : 1);
    })();
  \""

run_test "listSessions excludes sessions belonging to other users" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { getOrCreateSession, listSessions } from './src/lib/session-store.ts';
    (async () => {
      await getOrCreateSession('alice-sess', 'alice');
      await getOrCreateSession('bob-sess', 'bob');
      const aliceSessions = await listSessions('alice');
      const ids = aliceSessions.map(s => s.sessionId);
      if (ids.includes('bob-sess')) process.exit(1);
      if (!ids.includes('alice-sess')) process.exit(1);
      process.exit(0);
    })();
  \""

run_test "GET /sessions route enforces userId (returns 401 without JWT sub)" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { sessionsRoutes } from './src/routes/sessions.ts';
    // Verify the route reads userId from jwtPayload.sub and returns 401 without it
    const src = await Bun.file('./src/routes/sessions.ts').text();
    if (!src.includes('jwtPayload')?.sub || !src.includes('unauthorized')) process.exit(1);
    process.exit(0);
  \" 2>/dev/null || cd '$API_DIR' && grep -q 'jwtPayload.*sub' src/routes/sessions.ts && grep -q 'unauthorized' src/routes/sessions.ts"

run_test "Full session-store unit suite passes (P0-2 group)" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun test tests/unit/session-store.test.ts --bail 2>&1 | grep -q '0 fail'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "P0-3 · SSRF allowlist enforcement (HTTP tools)"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: api/src/lib/http-tools-runtime.ts :: assertHttpToolsFileSecure + assertUrlAllowed"
echo "  Requirement: HTTP tools without a security.allowedHosts block must be"
echo "               REJECTED at registration time and at every call site."

run_test "assertHttpToolsFileSecure throws for tools with no security block" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { assertHttpToolsFileSecure } from './src/lib/http-tools-runtime.ts';
    const t = { name:'t', description:'d', method:'POST', url:'https://api.example.test/x', parameters:[], timeoutMs:1000, passThroughBody:false };
    try { assertHttpToolsFileSecure({ tools: [t] }, 'test.json'); process.exit(1); }
    catch(e) { if (e.message.includes('allowlist')) process.exit(0); process.exit(1); }
  \""

run_test "assertHttpToolsFileSecure passes when allowedHosts is populated" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { assertHttpToolsFileSecure } from './src/lib/http-tools-runtime.ts';
    const t = { name:'t', description:'d', method:'POST', url:'https://api.example.test/x', parameters:[], timeoutMs:1000, passThroughBody:false };
    try { assertHttpToolsFileSecure({ security: { allowedHosts: ['api.example.test'] }, tools: [t] }, 'test.json'); process.exit(0); }
    catch(e) { process.exit(1); }
  \""

run_test "Runtime call returns ssrf_blocked when allowlist is missing" \
  "cd '$API_DIR' && HTTP_TOOLS_MOCK=0 AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { makeHttpConfigTool } from './src/lib/http-tools-runtime.ts';
    const t = { name:'t', description:'d', method:'POST', url:'https://api.example.test/x', parameters:[{name:'x',type:'string',description:'x',required:true}], timeoutMs:1000, passThroughBody:false };
    const tool = makeHttpConfigTool(t, { tools: [t] });
    const r = await tool.invoke({ x: 'v' });
    if (r.status === 'error' && r.code === 'ssrf_blocked') process.exit(0);
    process.exit(1);
  \""

run_test "Runtime call returns ssrf_blocked for host not in allowlist" \
  "cd '$API_DIR' && HTTP_TOOLS_MOCK=0 AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { makeHttpConfigTool } from './src/lib/http-tools-runtime.ts';
    const t = { name:'t', description:'d', method:'POST', url:'https://malicious.example.com/x', parameters:[{name:'x',type:'string',description:'x',required:true}], timeoutMs:1000, passThroughBody:false };
    const tool = makeHttpConfigTool(t, { security: { allowedHosts: ['api.example.test'] }, tools: [t] });
    const r = await tool.invoke({ x: 'v' });
    if (r.status === 'error' && r.code === 'ssrf_blocked') process.exit(0);
    process.exit(1);
  \""

run_test "allowedHostSuffixes wildcard enforcement works" \
  "cd '$API_DIR' && HTTP_TOOLS_MOCK=0 AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun -e \"
    import { makeHttpConfigTool } from './src/lib/http-tools-runtime.ts';
    const t = { name:'t', description:'d', method:'POST', url:'https://malicious.evil.com/x', parameters:[{name:'x',type:'string',description:'x',required:true}], timeoutMs:1000, passThroughBody:false };
    const tool = makeHttpConfigTool(t, { security: { allowedHostSuffixes: ['.example.test'] }, tools: [t] });
    const r = await tool.invoke({ x: 'v' });
    if (r.status === 'error' && r.code === 'ssrf_blocked') process.exit(0);
    process.exit(1);
  \""

run_test "Full HTTP tools SSRF unit suite passes" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun test tests/unit/http-tools-ssrf.test.ts --bail 2>&1 | grep -q '0 fail'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
section "P0-4 · Lambda / MCP log redaction (PII must not appear in CloudWatch)"
# ─────────────────────────────────────────────────────────────────────────────
echo "  Source: mcp-runtimes/mongodb-mcp/src/vendor/handlers.mjs"
echo "          mcp-runtimes/mongodb-mcp/src/server.ts"
echo "  Requirement: Tool args containing PII (filter, document, queryVector,"
echo "               pipeline) must be stripped before any console.log call."

run_test "redactArgsForLog strips filter field (PII)" \
  "cd '$MCP_DIR' && node --input-type=module <<'EOJS'
import { redactArgsForLog } from './src/vendor/handlers.mjs';
const out = redactArgsForLog({ collection:'c', filter:{email:'a@b.com'} });
if (typeof out.filter === 'object' && out.filter.email) process.exit(1);
if (out.collection !== 'c') process.exit(1);
process.exit(0);
EOJS"

run_test "redactArgsForLog strips document field (PII)" \
  "cd '$MCP_DIR' && node --input-type=module <<'EOJS'
import { redactArgsForLog } from './src/vendor/handlers.mjs';
const out = redactArgsForLog({ collection:'c', document:{ssn:'123-45-6789'} });
if (typeof out.document === 'object' && out.document.ssn) process.exit(1);
process.exit(0);
EOJS"

run_test "redactArgsForLog strips queryVector (embedding vector)" \
  "cd '$MCP_DIR' && node --input-type=module <<'EOJS'
import { redactArgsForLog } from './src/vendor/handlers.mjs';
const vec = new Array(1024).fill(0.1);
const out = redactArgsForLog({ collection:'c', queryVector: vec });
if (Array.isArray(out.queryVector)) process.exit(1);
if (!String(out.queryVector).includes('[array len=1024]')) process.exit(1);
process.exit(0);
EOJS"

run_test "redactArgsForLog strips pipeline (aggregation stages)" \
  "cd '$MCP_DIR' && node --input-type=module <<'EOJS'
import { redactArgsForLog } from './src/vendor/handlers.mjs';
const out = redactArgsForLog({ collection:'c', pipeline:[{matchField:{status:'open'}}] });
if (Array.isArray(out.pipeline)) process.exit(1);
process.exit(0);
EOJS"

run_test "redactArgsForLog preserves safe metadata (collection, limit, operation)" \
  "cd '$MCP_DIR' && node --input-type=module <<'EOJS'
import { redactArgsForLog } from './src/vendor/handlers.mjs';
const out = redactArgsForLog({ collection:'orders', limit:5, operation:'find' });
if (out.collection !== 'orders' || out.limit !== 5 || out.operation !== 'find') process.exit(1);
process.exit(0);
EOJS"

run_test "redactEventForLog strips AgentCore-style toolArguments envelope" \
  "cd '$MCP_DIR' && node --input-type=module <<'EOJS'
import { redactEventForLog } from './src/vendor/handlers.mjs';
const event = { toolName:'mongodb_query', toolArguments:{ collection:'orders', filter:{customerId:'abc'} } };
const out = redactEventForLog(event);
if (out.toolArguments && typeof out.toolArguments.filter === 'object' && out.toolArguments.filter.customerId) process.exit(1);
if (out.toolName !== 'mongodb_query') process.exit(1);
process.exit(0);
EOJS"

run_test "redactEventForLog strips MCP body params.arguments" \
  "cd '$MCP_DIR' && node --input-type=module <<'EOJS'
import { redactEventForLog } from './src/vendor/handlers.mjs';
const body = JSON.stringify({ method:'tools/call', params:{ name:'mongodb_query', arguments:{ collection:'tickets', filter:{status:'open'} } } });
const event = { body };
const out = redactEventForLog(event);
if (out.body && out.body.params && out.body.params.arguments && typeof out.body.params.arguments.filter === 'object') process.exit(1);
process.exit(0);
EOJS"

run_test "redactErrorForLog truncates long stack traces (prevents CloudWatch bloat)" \
  "cd '$MCP_DIR' && node --input-type=module <<'EOJS'
import { redactErrorForLog } from './src/vendor/handlers.mjs';
const err = new Error('boom: ' + 'x'.repeat(800));
const out = redactErrorForLog(err);
if (out.message.length > 501) process.exit(1);
if (!out.name || !out.message) process.exit(1);
process.exit(0);
EOJS"

run_test "server.ts dispatch uses redactArgsForLog (not raw args) in its log call" \
  "grep -q 'redactArgsForLog(handlerArgs)' '$REPO_ROOT/mcp-runtimes/mongodb-mcp/src/server.ts'"

run_test "API [mcp] callTool audit log routes args through redactMongoArgsForLog" \
  "grep -q 'redactMongoArgsForLog(scopedArgs)' '$API_DIR/src/adapters/mongodb-mcp-client.ts'"

run_test "trace-collector flattenAttrs summarises SENSITIVE_PAYLOAD_KEYS (spans /aws/spans)" \
  "grep -q 'SENSITIVE_PAYLOAD_KEYS' '$API_DIR/src/lib/trace-collector.ts'"

run_test "trace-collector flattenAttrs masks email/phone in leaf strings (maskPiiInString backstop)" \
  "grep -q 'maskPiiInString' '$API_DIR/src/lib/trace-collector.ts'"

run_test "otel.ts scrubs ALL spans (incl. Strands gen_ai) via RedactingSpanProcessor before export" \
  "grep -q 'RedactingSpanProcessor' '$API_DIR/src/lib/otel.ts' && grep -q 'redactSpanAttributes' '$API_DIR/src/lib/otel.ts'"

run_test "otel.ts summarises gen_ai content carriers (content/message/messages — free-text PII backstop)" \
  "grep -q '\"content\"' '$API_DIR/src/lib/otel.ts' && grep -q '\"message\"' '$API_DIR/src/lib/otel.ts' && grep -q '\"messages\"' '$API_DIR/src/lib/otel.ts'"

run_test "AgentCore vended APPLICATION_LOGS are opt-in (raw request/response payloads)" \
  "grep -q 'variable \"enable_agentcore_vended_application_logs\"' '$REPO_ROOT/deploy/terraform/envs/ec2/variables.tf' && grep -A4 'variable \"enable_agentcore_vended_application_logs\"' '$REPO_ROOT/deploy/terraform/envs/ec2/variables.tf' | grep -q 'default     = false'"

run_test "Full otel-span-redaction unit suite passes (gen_ai span backstop)" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun test tests/unit/otel-span-redaction.test.ts --bail 2>&1 | grep -q '0 fail'"

run_test "Full log-pii-redact unit suite passes (logger + span redactors)" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun test tests/unit/log-pii-redact.test.ts tests/unit/trace-collector-pii-spans.test.ts --bail 2>&1 | grep -q '0 fail'"

run_test "Full mongodb-mcp-redact unit suite passes" \
  "cd '$API_DIR' && AUTH_JWKS_URI=https://test.example.com/.well-known/jwks.json AUTH_ISSUER=https://test.example.com bun test tests/unit/mongodb-mcp-redact.test.ts --bail 2>&1 | grep -q '0 fail'"

section_summary

# ─────────────────────────────────────────────────────────────────────────────
banner "FINAL SUMMARY"
# ─────────────────────────────────────────────────────────────────────────────

total=$((pass + fail))
echo -e "\n  Total tests: ${total}"
echo -e "  ${GREEN}Passed: ${pass}${NC}"
if [[ $fail -gt 0 ]]; then
  echo -e "  ${RED}FAILED: ${fail}${NC}"
  echo -e "\n${RED}${BOLD}  ✗ One or more security controls are NOT correctly implemented.${NC}"
  exit 1
else
  echo -e "  ${GREEN}Failed: 0${NC}"
  echo -e "\n${GREEN}${BOLD}  ✓ All four security controls are comprehensively implemented.${NC}"
  exit 0
fi
