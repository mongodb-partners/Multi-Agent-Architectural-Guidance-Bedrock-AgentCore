#!/usr/bin/env bash
# Comprehensive E2E smoke test for the deployed stack.
#
# What it covers:
#   1. /health — all dependencies connected
#   2. Auth — Cognito JWT obtained from alex@example.com
#   3. Product recommendation chat — should fire mongodb_vector_search via Voyage
#   4. Troubleshooting chat — should fire mongodb_vector_search + maybe bedrock_kb_retrieve
#   5. Order management chat — mongodb_query path (no embedding)
#   6. Long-term memory — turn 1 sets a fact, turn 2 recalls it
#   7. Trace assertions for each chat — verify mongo.vector_search payload structure
#
# Usage: bash e2e-smoke/e2e-smoke.sh
# Reads API_URL from `terraform output -raw ec2_api_url`, or defaults to current EC2 IP.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# ── resolve API_URL and Cognito creds from .env.live / .env
if [[ -f .env.live ]]; then
  API_URL="$(grep '^STREAMLIT_API_URL=' .env.live | sed 's/STREAMLIT_API_URL=//' | sed 's:/$::' )"
  COGNITO_CLIENT_ID="$(grep '^STREAMLIT_COGNITO_CLIENT_ID=' .env.live | sed 's/STREAMLIT_COGNITO_CLIENT_ID=//')"
fi
API_URL="${API_URL:-http://3.230.249.151:3000}"
COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:-}"
COGNITO_USER="${E2E_USER:-alex@example.com}"
COGNITO_PASS="${E2E_PASS:-DemoUser#2026}"

pass=0
fail=0
warn=0
checks=()

assert() {
  local name="$1" cond="$2" detail="${3:-}"
  if [[ "$cond" == "1" ]]; then
    pass=$((pass+1)); checks+=("PASS  $name${detail:+ — $detail}"); echo "  PASS  $name${detail:+ — $detail}"
  else
    fail=$((fail+1)); checks+=("FAIL  $name${detail:+ — $detail}"); echo "  FAIL  $name${detail:+ — $detail}"
  fi
}
warn_check() {
  warn=$((warn+1)); checks+=("WARN  $1"); echo "  WARN  $1"
}

# ─── 1. Health ───────────────────────────────────────────────────────────────
echo ""
echo "═══ 1. Health check ($API_URL) ═══"
HEALTH="$(curl -s --max-time 15 "$API_URL/health" 2>/dev/null)"
echo "  raw: $HEALTH" | head -c 400; echo
for dep in mongodb longTermMemory agentcore mcpServer; do
  ok=$(echo "$HEALTH" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('dependencies',{}).get('$dep',''); print(1 if v=='connected' else 0)" 2>/dev/null || echo 0)
  assert "health.$dep connected" "$ok" "$(echo "$HEALTH" | python3 -c "import json,sys; print(json.load(sys.stdin).get('dependencies',{}).get('$dep','?'))" 2>/dev/null)"
done
# Optional KB probe when manifest carries bedrock_kb_id
KB_ID="${BEDROCK_KB_ID:-}"
if [[ -n "$KB_ID" ]]; then
  ok=$(echo "$HEALTH" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('dependencies',{}).get('bedrockKnowledgeBase',''); print(1 if v=='connected' else 0)" 2>/dev/null || echo 0)
  assert "health.bedrockKnowledgeBase connected" "$ok" "$(echo "$HEALTH" | python3 -c "import json,sys; print(json.load(sys.stdin).get('dependencies',{}).get('bedrockKnowledgeBase','?'))" 2>/dev/null)"
fi

# ─── 2. Auth ─────────────────────────────────────────────────────────────────
echo ""
echo "═══ 2. Cognito auth ═══"
if [[ -z "$COGNITO_CLIENT_ID" ]]; then
  warn_check "STREAMLIT_COGNITO_CLIENT_ID not in .env.live; skipping auth-dependent tests"
  TOKEN=""
else
  TOKEN=$(aws cognito-idp initiate-auth \
    --client-id "$COGNITO_CLIENT_ID" \
    --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=$COGNITO_USER,PASSWORD=$COGNITO_PASS" \
    --query 'AuthenticationResult.IdToken' --output text 2>&1)
  if [[ ${#TOKEN} -gt 100 ]]; then
    assert "cognito.token obtained" 1 "len=${#TOKEN}"
  else
    assert "cognito.token obtained" 0 "$TOKEN"
    TOKEN=""
  fi
fi

# Helper: SSE chat, write to file, return path
chat() {
  local agentId="$1" sessionId="$2" message="$3" out="$4"
  curl -s --max-time 240 -N \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$API_URL/chat" \
    -d "{\"message\":$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$message"),\"sessionId\":\"$sessionId\",\"agentId\":\"$agentId\"}" \
    > "$out" 2>&1
}

extract() {
  local sse="$1" filter="$2"
  python3 -c "
import json, re, sys
with open('$sse') as f: data = f.read()
for ev in re.finditer(r'event: (\w+)\ndata: (.+)', data):
    et = ev.group(1); body = ev.group(2)
    if et != 'trace': continue
    try:
        d = json.loads(body)
        if d.get('type') == '$filter':
            print(json.dumps(d.get('payload',{})))
    except: pass
"
}

tokens_text() {
  python3 -c "
import json, re
with open('$1') as f: data = f.read()
toks=[]
for ev in re.finditer(r'event: (\w+)\ndata: (.+)', data):
    if ev.group(1) == 'token':
        try: toks.append(json.loads(ev.group(2)).get('text',''))
        except: pass
print(''.join(toks))
"
}

# ─── 3. Product recommendation ───────────────────────────────────────────────
if [[ -n "$TOKEN" ]]; then
  echo ""
  echo "═══ 3. Product recommendation (vector search) ═══"
  SID="e2e-pr-$(date +%s)"
  chat "product-recommendation" "$SID" "I need waterproof outdoor headphones IP67 under \$80" /tmp/e2e_pr.sse
  echo "  bytes: $(wc -c < /tmp/e2e_pr.sse)"
  VS_ALL=$(extract /tmp/e2e_pr.sse mongo.vector_search)
  if [[ -n "$VS_ALL" ]]; then
    # Aggregate across all mongo.vector_search events from this turn: the model may
    # over-filter on a first attempt (e.g. filter:{price:{$lte:80}} against an
    # index that doesn't declare price as a filter field → 0 hits, no scores)
    # and recover on the next call. Only the aggregate matters for "did vector
    # search actually work this turn".
    AGG=$(echo "$VS_ALL" | python3 -c "
import json, sys
src=set(); dims=set(); have_scores=False; n=0
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    p=json.loads(line); n+=1
    src.add(p.get('embeddingSource','?'))
    qv=p.get('queryVectorPreview',{})
    if qv.get('length') is not None: dims.add(qv['length'])
    s=p.get('scoreSummary')
    if s and s.get('avg') is not None: have_scores=True
print(n, ','.join(sorted(map(str,src))), ','.join(sorted(map(str,dims))), 'yes' if have_scores else 'no')
")
    read -r N SRC DIMS HAS_SCORES <<<"$AGG"
    assert "pr.mongo.vector_search emitted" 1 "n=$N"
    assert "pr.embeddingSource=voyage" "$([ "$SRC" = "voyage" ] && echo 1 || echo 0)" "got $SRC"
    assert "pr.queryVector length=1024" "$([ "$DIMS" = "1024" ] && echo 1 || echo 0)" "got $DIMS"
    assert "pr.scoreSummary present (any call)" "$([ "$HAS_SCORES" = "yes" ] && echo 1 || echo 0)" "has_scores=$HAS_SCORES"
  else
    assert "pr.mongo.vector_search emitted" 0
  fi
  TXT=$(tokens_text /tmp/e2e_pr.sse)
  echo "  reply (first 250 chars): ${TXT:0:250}"
  assert "pr.reply mentions IP67 or SKU-7" "$(echo "$TXT" | grep -qiE 'IP67|SKU-7|outdoor widget rugged' && echo 1 || echo 0)"

  # ─── 4. Troubleshooting ───────────────────────────────────────────────────
  echo ""
  echo "═══ 4. Troubleshooting (vector search on troubleshooting_docs) ═══"
  SID="e2e-ts-$(date +%s)"
  chat "troubleshooting" "$SID" "My device won't turn on after I left it in the rain" /tmp/e2e_ts.sse
  echo "  bytes: $(wc -c < /tmp/e2e_ts.sse)"
  VS=$(extract /tmp/e2e_ts.sse mongo.vector_search | head -1)
  if [[ -n "$VS" ]]; then
    SRC=$(echo "$VS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('embeddingSource','?'))")
    assert "ts.mongo.vector_search emitted" 1
    assert "ts.embeddingSource=voyage" "$([ "$SRC" = "voyage" ] && echo 1 || echo 0)" "got $SRC"
  else
    warn_check "ts.mongo.vector_search not emitted (agent may have routed to keyword path)"
  fi

  # ─── 5. Order management ──────────────────────────────────────────────────
  echo ""
  echo "═══ 5. Order management (mongodb_query, no embedding) ═══"
  SID="e2e-om-$(date +%s)"
  chat "order-management" "$SID" "What's the status of order ORD-1001?" /tmp/e2e_om.sse
  echo "  bytes: $(wc -c < /tmp/e2e_om.sse)"
  MI=$(extract /tmp/e2e_om.sse mongo.intent | head -1)
  assert "om.mongo.intent emitted (orders collection)" "$([ -n "$MI" ] && echo "$MI" | grep -qi orders && echo 1 || echo 0)"
  TXT=$(tokens_text /tmp/e2e_om.sse)
  echo "  reply (first 250 chars): ${TXT:0:250}"

  # ─── 6. Long-term memory across sessions (hybrid vector + BM25) ──────────
  echo ""
  echo "═══ 6. Long-term memory (cross-session hybrid recall) ═══"
  SID1="e2e-mem1-$(date +%s)"
  MEM_ALLERGEN="lychee"
  chat "product-recommendation" "$SID1" "I have a ${MEM_ALLERGEN} allergy, please remember that for future product suggestions" /tmp/e2e_mem1.sse
  # Assert turn 1 actually committed a long-term write (writer is fail-closed:
  # if Bedrock model access is missing it emits memory.long_term_skip instead).
  MEM_WRITE=$(extract /tmp/e2e_mem1.sse memory.long_term_write | head -1)
  MEM_SKIP=$(extract /tmp/e2e_mem1.sse memory.long_term_skip | head -1)
  if [[ -n "$MEM_SKIP" ]]; then
    REASON=$(echo "$MEM_SKIP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reason','?'))")
    assert "memory.long_term_write emitted" 0 "skip reason=$REASON"
  elif [[ -n "$MEM_WRITE" ]]; then
    assert "memory.long_term_write emitted" "$([ -n "$MEM_WRITE" ] && echo 1 || echo 0)"
    # New: assert bulkWrite op + embeddedCount + embeddingModel are reported.
    # These appeared with the hybrid retrieval refactor — older payloads said op=insertMany.
    OP=$(echo "$MEM_WRITE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('op',''))" 2>/dev/null || echo "")
    EMB=$(echo "$MEM_WRITE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('embeddedCount',''))" 2>/dev/null || echo "")
    DUP=$(echo "$MEM_WRITE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('duplicatesSkipped',''))" 2>/dev/null || echo "")
    MDL=$(echo "$MEM_WRITE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('embeddingModel',''))" 2>/dev/null || echo "")
    assert "memory.long_term_write op=bulkWrite" "$([ "$OP" = "bulkWrite" ] && echo 1 || echo 0)" "op=$OP"
    assert "memory.long_term_write payload has embeddedCount + duplicatesSkipped + embeddingModel" \
      "$([ -n "$EMB" ] && [ -n "$DUP" ] && [ -n "$MDL" ] && echo 1 || echo 0)" \
      "embedded=$EMB duplicates=$DUP model=$MDL"
  else
    # Runtime mode intentionally performs long-term fact extraction after `done`
    # so it does not hold the SSE response open. In that mode the write trace
    # may not appear in this stream; the recall assertion below is the live
    # end-to-end proof that LTM persistence/retrieval works.
    echo "  note  memory.long_term_write trace not in SSE stream (post-done async writer); recall assertion proves persistence"
  fi
  # Poll instead of a fixed sleep — the write is async (microtask + bulkWrite + embed).
  # Try up to 8 attempts × 2s each (16s) before declaring the fact unrecallable.
  MEM_HIT=0; MEM_DENIAL=0; RECALL_TXT=""; SCOPED_READ=""
  for attempt in 1 2 3 4 5 6 7 8; do
    SID2="e2e-mem2-$(date +%s)-${attempt}"
    chat "product-recommendation" "$SID2" "What did I tell you about ${MEM_ALLERGEN} allergies?" /tmp/e2e_mem2.sse
    RECALL_TXT=$(tokens_text /tmp/e2e_mem2.sse)
    SCOPED_READ=$(extract /tmp/e2e_mem2.sse memory.scoped_read | head -1)
    MEM_HIT=$(echo "$RECALL_TXT" | grep -qi "$MEM_ALLERGEN" && echo 1 || echo 0)
    MEM_DENIAL=$(echo "$RECALL_TXT" | grep -qiE "don't have|no information|haven't mentioned|don't recall|no allergies" && echo 1 || echo 0)
    if [[ "$MEM_HIT" = "1" && "$MEM_DENIAL" = "0" ]]; then
      echo "  recall hit on attempt ${attempt}"
      break
    fi
    sleep 2
  done
  echo "  recall reply (last attempt, first 300 chars): ${RECALL_TXT:0:300}"
  # Must mention the run's allergen AND must NOT be a denial. Plain `grep allerg` matches
  # "no allergies in your profile" — false positive that hid the fact extractor
  # being broken in an earlier iteration.
  assert "memory.recalls ${MEM_ALLERGEN} allergy (positive, not a denial)" \
    "$([ "$MEM_HIT" = "1" ] && [ "$MEM_DENIAL" = "0" ] && echo 1 || echo 0)" \
    "hit=$MEM_HIT denial=$MEM_DENIAL"
  # Soft-assert hybrid retrieval shape: the new memory.scoped_read payload should carry
  # `mode: "hybrid"` and a `retrieval` object. Warn-only — older runtimes still satisfy
  # the recall test above without the enrichment.
  if [[ -n "$SCOPED_READ" ]]; then
    MODE=$(echo "$SCOPED_READ" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mode',''))" 2>/dev/null || echo "")
    HAS_RETRIEVAL=$(echo "$SCOPED_READ" | python3 -c "import json,sys; print(1 if isinstance(json.load(sys.stdin).get('retrieval'), dict) else 0)" 2>/dev/null || echo 0)
    if [[ "$MODE" = "hybrid" && "$HAS_RETRIEVAL" = "1" ]]; then
      echo "  ✓ memory.scoped_read carries mode=hybrid + retrieval{...} (hybrid path is live)"
    else
      echo "  ⚠ memory.scoped_read missing hybrid enrichment (mode=$MODE, retrieval=$HAS_RETRIEVAL) — older runtime or vector indexes not seeded"
      warn=$((warn+1))
    fi
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "═══ Summary ═══"
echo "  PASS: $pass"
echo "  FAIL: $fail"
echo "  WARN: $warn"
echo ""
for c in "${checks[@]}"; do echo "  $c"; done

if [[ "${RUN_LTM_DEEP:-0}" == "1" || "${RUN_LTM_DEEP:-}" == "true" ]]; then
  echo ""
  echo "═══ Optional LTM deep smoke (RUN_LTM_DEEP=${RUN_LTM_DEEP}) ═══"
  bash "$PROJECT_ROOT/e2e-smoke/ltm/ltm-smoke.sh" || fail=$((fail+1))
fi

[[ $fail -eq 0 ]] && exit 0 || exit 1
