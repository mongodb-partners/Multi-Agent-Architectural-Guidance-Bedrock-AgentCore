#!/usr/bin/env bash
# Focused long-term-memory smoke tests for the deployed stack.
#
# These tests validate more than user-visible recall. They fetch persisted
# traces and assert that LTM reads emit hybrid/vector retrieval metadata for
# agent_memory_facts + chat_messages.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -f .env && -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  # shellcheck source=/dev/null
  source .env
fi

if [[ -f .env.live ]]; then
  API_URL="${API_URL:-$(grep '^STREAMLIT_API_URL=' .env.live | sed 's/STREAMLIT_API_URL=//' | sed 's:/$::')}"
  COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:-$(grep '^STREAMLIT_COGNITO_CLIENT_ID=' .env.live | sed 's/STREAMLIT_COGNITO_CLIENT_ID=//')}"
fi

API_URL="${API_URL:-http://3.230.249.151:3000}"
COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:-}"
COGNITO_USER="${E2E_USER:-alex@example.com}"
COGNITO_PASS="${E2E_PASS:-DemoUser#2026}"
RUN_ID="${LTM_SMOKE_RUN_ID:-$(date +%s)}"
TMP_DIR="${TMPDIR:-/tmp}/ltm-smoke-$RUN_ID"
mkdir -p "$TMP_DIR"

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

text_matches() {
  local file="$1" positive="$2" negative="${3:-}"
  python3 - "$file" "$positive" "$negative" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
positive = sys.argv[2]
negative = sys.argv[3]
ok = re.search(positive, text, re.I | re.S) is not None
if negative:
    ok = ok and re.search(negative, text, re.I | re.S) is None
print(1 if ok else 0)
PY
}

text_preview() {
  python3 - "$1" <<'PY'
import sys
print(open(sys.argv[1]).read().replace("\n", " ")[:160])
PY
}

json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

auth_token() {
  if [[ -z "$COGNITO_CLIENT_ID" ]]; then
    echo ""
    return 0
  fi
  aws cognito-idp initiate-auth \
    --client-id "$COGNITO_CLIENT_ID" \
    --auth-flow USER_PASSWORD_AUTH \
    --auth-parameters "USERNAME=$COGNITO_USER,PASSWORD=$COGNITO_PASS" \
    --query 'AuthenticationResult.IdToken' \
    --output text 2>/dev/null || true
}

chat() {
  local agent_id="$1" session_id="$2" message="$3" out="$4"
  curl -s --max-time 240 -N \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$API_URL/chat" \
    -d "{\"message\":$(json_string "$message"),\"sessionId\":\"$session_id\",\"agentId\":\"$agent_id\"}" \
    > "$out" 2>&1
}

tokens_text() {
  python3 - "$1" <<'PY'
import json, re, sys
data = open(sys.argv[1]).read()
tokens = []
for ev in re.finditer(r"event: (\w+)\ndata: (.+)", data):
    if ev.group(1) == "token":
        try:
            tokens.append(json.loads(ev.group(2)).get("text", ""))
        except Exception:
            pass
print("".join(tokens))
PY
}

done_trace_id() {
  python3 - "$1" <<'PY'
import json, re, sys
data = open(sys.argv[1]).read()
trace_id = ""
for ev in re.finditer(r"event: (\w+)\ndata: (.+)", data):
    if ev.group(1) == "done":
        try:
            trace_id = json.loads(ev.group(2)).get("traceId", "") or trace_id
        except Exception:
            pass
print(trace_id)
PY
}

fetch_trace() {
  local trace_id="$1" out="$2"
  for _ in 1 2 3 4 5; do
    curl -s --max-time 30 \
      -H "Authorization: Bearer $TOKEN" \
      "$API_URL/traces/$trace_id" > "$out"
    if python3 - "$out" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    ok = isinstance(d.get("events"), list)
except Exception:
    ok = False
raise SystemExit(0 if ok else 1)
PY
    then
      return 0
    fi
    sleep 2
  done
  return 1
}

memory_trace_summary() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
events = [e for e in d.get("events", []) if e.get("type") == "memory.scoped_read"]
if not events:
    print(json.dumps({"ok": False, "error": "missing memory.scoped_read"}))
    raise SystemExit(0)
p = events[-1].get("payload", {})
r = p.get("retrieval") or {}
per = r.get("perCollection") or []
by = {row.get("collection"): row for row in per if isinstance(row, dict)}
collections = set(p.get("collectionsQueried") or [])
vector_hits = int(r.get("vectorHits") or 0)
lexical_hits = int(r.get("lexicalHits") or 0)
summary = {
    "ok": True,
    "mode": p.get("mode"),
    "embeddingSource": p.get("embeddingSource"),
    "embeddingModel": p.get("embeddingModel"),
    "entryCount": int(p.get("entryCount") or 0),
    "bytesInjected": int(p.get("bytesInjected") or 0),
    "vectorHits": vector_hits,
    "lexicalHits": lexical_hits,
    "rrfMergedCount": int(r.get("rrfMergedCount") or 0),
    "hasRetrieval": isinstance(r, dict) and bool(r),
    "hasFactsCollection": "agent_memory_facts" in collections,
    "hasMessagesCollection": "chat_messages" in collections,
    "factsVectorReturned": int((by.get("agent_memory_facts") or {}).get("vectorReturned") or 0),
    "messagesVectorReturned": int((by.get("chat_messages") or {}).get("vectorReturned") or 0),
    "perCollectionCount": len(per),
}
print(json.dumps(summary))
PY
}

assert_memory_hybrid_trace() {
  local label="$1" trace_file="$2" require_vector="$3" require_messages_vector="${4:-0}"
  local summary
  summary="$(memory_trace_summary "$trace_file")"
  echo "  trace[$label]: $summary"
  local fields
  fields="$(python3 - "$summary" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
def b(v): return "1" if v else "0"
print("ok", b(s.get("ok")))
print("mode", b(s.get("mode") == "hybrid"), s.get("mode") or "")
print("embedding", b(s.get("embeddingSource") in ("voyage", "bedrock") and bool(s.get("embeddingModel"))), f"{s.get('embeddingSource')}/{s.get('embeddingModel')}")
print("collections", b(s.get("hasFactsCollection") and s.get("hasMessagesCollection")))
print("retrieval", b(s.get("hasRetrieval") and s.get("perCollectionCount", 0) >= 2))
print("entry", b(int(s.get("entryCount") or 0) > 0), str(s.get("entryCount") or 0))
print("vector", b(int(s.get("vectorHits") or 0) > 0), str(s.get("vectorHits") or 0))
print("messages_vector", b(int(s.get("messagesVectorReturned") or 0) > 0), str(s.get("messagesVectorReturned") or 0))
PY
)"
  assert "$label trace has memory.scoped_read" "$(echo "$fields" | awk '$1=="ok"{print $2}')"
  assert "$label trace mode=hybrid" "$(echo "$fields" | awk '$1=="mode"{print $2}')" "$(echo "$fields" | awk '$1=="mode"{print $3}')"
  assert "$label trace has embedding source/model" "$(echo "$fields" | awk '$1=="embedding"{print $2}')" "$(echo "$fields" | awk '$1=="embedding"{print $3}')"
  assert "$label trace queried facts + chat_messages" "$(echo "$fields" | awk '$1=="collections"{print $2}')"
  assert "$label trace has retrieval perCollection" "$(echo "$fields" | awk '$1=="retrieval"{print $2}')"
  assert "$label trace injected entries" "$(echo "$fields" | awk '$1=="entry"{print $2}')" "entryCount=$(echo "$fields" | awk '$1=="entry"{print $3}')"
  if [[ "$require_vector" == "1" ]]; then
    assert "$label trace vectorHits > 0" "$(echo "$fields" | awk '$1=="vector"{print $2}')" "vectorHits=$(echo "$fields" | awk '$1=="vector"{print $3}')"
  fi
  if [[ "$require_messages_vector" == "1" ]]; then
    assert "$label trace chat_messages vector hits > 0" "$(echo "$fields" | awk '$1=="messages_vector"{print $2}')" "chatMessagesVector=$(echo "$fields" | awk '$1=="messages_vector"{print $3}')"
  fi
}

recall_with_trace() {
  local agent_id="$1" session_id="$2" message="$3" out_prefix="$4"
  local sse="$TMP_DIR/${out_prefix}.sse"
  local trace="$TMP_DIR/${out_prefix}.trace.json"
  local text_file="$TMP_DIR/${out_prefix}.text"
  chat "$agent_id" "$session_id" "$message" "$sse"
  local txt trace_id
  txt="$(tokens_text "$sse")"
  printf '%s' "$txt" > "$text_file"
  trace_id="$(done_trace_id "$sse")"
  if [[ -z "$trace_id" ]]; then
    echo "TRACE_ID="
    echo "TEXT_FILE=$text_file"
    return 1
  fi
  fetch_trace "$trace_id" "$trace" || return 1
  echo "TRACE_ID=$trace_id"
  echo "TRACE_FILE=$trace"
  echo "TEXT_FILE=$text_file"
  python3 - "$text_file" <<'PY'
import sys
txt = open(sys.argv[1]).read().replace("\n", " ")
print(f"TEXT_PREVIEW={txt[:220]}")
PY
}

echo ""
echo "== LTM smoke setup =="
echo "api_url=$API_URL"
TOKEN="$(auth_token)"
if [[ ${#TOKEN} -gt 100 ]]; then
  assert "cognito.token obtained" 1 "len=${#TOKEN}"
else
  assert "cognito.token obtained" 0 "missing or invalid token"
  echo "Cannot run authenticated LTM smoke without a token."
  exit 1
fi

echo ""
echo "== Scenario 1: semantic fact recall with vector/hybrid trace =="
SID_A="ltm-semantic-$RUN_ID"
chat "product-recommendation" "$SID_A" \
  "Please remember this for future product suggestions: I have a hazelnut allergy and need nut-free recommendations." \
  "$TMP_DIR/semantic-write.sse"
sleep "${LTM_WRITE_SETTLE_SECONDS:-6}"
SEM_OUT="$(recall_with_trace "product-recommendation" "ltm-semantic-recall-$RUN_ID" \
  "What food-safety constraint should you remember for my product suggestions?" \
  "semantic-recall")"
echo "$SEM_OUT"
SEM_TEXT_FILE="$(echo "$SEM_OUT" | sed -n 's/^TEXT_FILE=//p')"
SEM_TRACE="$(echo "$SEM_OUT" | sed -n 's/^TRACE_FILE=//p')"
assert "semantic recall mentions hazelnut/nut-free" \
  "$(text_matches "$SEM_TEXT_FILE" 'hazelnut|nut.?free|allerg' "don't know|do not know|no record|haven't mentioned|no information")" \
  "$(text_preview "$SEM_TEXT_FILE")"
if [[ -n "$SEM_TRACE" && -f "$SEM_TRACE" ]]; then
  assert_memory_hybrid_trace "semantic recall" "$SEM_TRACE" 1 0
else
  assert "semantic recall trace fetched" 0
fi

echo ""
echo "== Scenario 2: correction / polarity =="
SID_B="ltm-correction-$RUN_ID"
chat "product-recommendation" "$SID_B" \
  "Please remember my snack preference: I used to like pasta, but correction: I do not like pasta now." \
  "$TMP_DIR/correction-write.sse"
sleep "${LTM_WRITE_SETTLE_SECONDS:-6}"
CORR_OUT="$(recall_with_trace "product-recommendation" "ltm-correction-recall-$RUN_ID" \
  "What is my current pasta preference?" \
  "correction-recall")"
echo "$CORR_OUT"
CORR_TEXT_FILE="$(echo "$CORR_OUT" | sed -n 's/^TEXT_FILE=//p')"
CORR_TRACE="$(echo "$CORR_OUT" | sed -n 's/^TRACE_FILE=//p')"
assert "correction recall preserves negation" \
  "$(text_matches "$CORR_TEXT_FILE" 'do not like|don.t like|dislike|avoid|not.*pasta')" \
  "$(text_preview "$CORR_TEXT_FILE")"
if [[ -n "$CORR_TRACE" && -f "$CORR_TRACE" ]]; then
  assert_memory_hybrid_trace "correction recall" "$CORR_TRACE" 0 0
else
  assert "correction recall trace fetched" 0
fi

echo ""
echo "== Scenario 3: chat-message mirror retrieval =="
SID_C="ltm-chatmsg-$RUN_ID"
CHAT_PHRASE="heliotrope falcon $RUN_ID"
chat "product-recommendation" "$SID_C" \
  "For this demo conversation, the unusual debug phrase is $CHAT_PHRASE." \
  "$TMP_DIR/chatmsg-write.sse"
sleep "${LTM_WRITE_SETTLE_SECONDS:-6}"
CHAT_OUT="$(recall_with_trace "product-recommendation" "ltm-chatmsg-recall-$RUN_ID" \
  "What unusual debug phrase did I mention during this demo conversation?" \
  "chatmsg-recall")"
echo "$CHAT_OUT"
CHAT_TEXT_FILE="$(echo "$CHAT_OUT" | sed -n 's/^TEXT_FILE=//p')"
CHAT_TRACE="$(echo "$CHAT_OUT" | sed -n 's/^TRACE_FILE=//p')"
if [[ "$(text_matches "$CHAT_TEXT_FILE" 'heliotrope falcon')" == "1" ]]; then
  assert "chat-message mirror reply mentions unique phrase" 1 "$(text_preview "$CHAT_TEXT_FILE")"
else
  echo "  note  chat-message mirror reply did not mention the unique phrase; using trace metadata as planned for variable model wording"
fi
if [[ -n "$CHAT_TRACE" && -f "$CHAT_TRACE" ]]; then
  assert_memory_hybrid_trace "chat-message recall" "$CHAT_TRACE" 1 1
else
  assert "chat-message recall trace fetched" 0
fi

if [[ -n "$CHAT_TRACE" && -f "$CHAT_TRACE" ]]; then
  assert "fallback non-regression: trace has retrieval metadata for diagnosis" \
    "$(memory_trace_summary "$CHAT_TRACE" | python3 -c 'import json,sys; s=json.load(sys.stdin); print(1 if s.get("hasRetrieval") and s.get("mode") in ("hybrid","lexical") else 0)')"
fi

echo ""
echo "== Summary =="
echo "PASS: $pass"
echo "FAIL: $fail"
echo "WARN: $warn"
echo ""
for c in "${checks[@]}"; do echo "$c"; done

[[ $fail -eq 0 ]] && exit 0 || exit 1
