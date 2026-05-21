#!/usr/bin/env bash
# _agents-common.sh — shared helpers sourced by deploy-project.sh and deploy-agents.sh.
#
# Do NOT execute directly.  Source with:
#   source "$SCRIPT_DIR/_agents-common.sh"
#
# Callers must have set before sourcing:
#   REPO_ROOT        absolute path to repository root
#   TF_DIR           absolute path to deploy/terraform/envs/ec2
#   AWS_REGION       e.g. us-east-1
#   PROJECT_NAME     e.g. multiagent-mongodb-framework
#   ENVIRONMENT      e.g. dev
#   SHARED_BUCKET    S3 bucket name (project-env-accountid)
#   GIT_SHA          short git SHA (used in S3 artifact prefix)
#   AGENTCORE_RUNTIME_DEPLOYMENT_MODE   container or code
#   AGENTCORE_CODE_ARTIFACT_PREFIX      S3 key for code zip
#
# Optional (needed only by update_runtime_env_dynamic):
#   MONGODB_URI, ATLAS_DB_NAME, BEDROCK_KB_ID, AGENTCORE_MEMORY_STORE_ID,
#   AGENTCORE_GATEWAY_URL, MONGODB_MCP_RUNTIME_ARN, MONGODB_MCP_RUNTIME_ENDPOINT,
#   VOYAGE_ENDPOINT, EMBEDDINGS_PROVIDER, VOYAGE_REQUEST_FORMAT
#
# Functions exported by this file:
#   apply_with_retry <plan_file> [terraform plan args...]
#   discover_agents              → sets AGENTS_JSON, ORCHESTRATOR_ID, SPECIALIST_IDS[]
#   write_specialist_agents_tfvars
#   validate_handoff_consistency
#   build_and_upload_code_artifact
#   build_dynamic_env_base      → sets DYNAMIC_ENV_BASE
#   update_runtime_env_dynamic
#   verify_runtime_env_dynamic
#   ensure_agent_config_refresh_token

# ─── Guard ────────────────────────────────────────────────────────────────────
# Prevent double-sourcing.
[[ -n "${_AGENTS_COMMON_SOURCED:-}" ]] && return 0
_AGENTS_COMMON_SOURCED=1

# ─── Tiny helpers (safe to redefine — callers already define compatible ones) ──
_ac_log()  { echo "  [agents] $*"; }
_ac_ok()   { echo "  [agents] ✓ $*"; }
_ac_warn() { echo "  [agents] ⚠ $*"; }
_ac_err()  { echo "  [agents] ✗ $*" >&2; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# ensure_agent_config_refresh_token
#
# Creates/loads the shared deploy-only token used by deploy-agents.sh to call
# POST /internal/agents/refresh on the API. Full/API deploys write this token
# into .env.live; agent-only deploys read the same local file when calling the
# endpoint. The file is gitignored and chmod 600.
# ══════════════════════════════════════════════════════════════════════════════
ensure_agent_config_refresh_token() {
  if [[ -n "${AGENT_CONFIG_REFRESH_TOKEN:-}" ]]; then
    export AGENT_CONFIG_REFRESH_TOKEN
    return 0
  fi

  local token_file="$REPO_ROOT/.agent-config-refresh-token"
  if [[ -f "$token_file" ]]; then
    AGENT_CONFIG_REFRESH_TOKEN="$(tr -d '[:space:]' < "$token_file")"
  else
    AGENT_CONFIG_REFRESH_TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
    umask 077
    printf '%s\n' "$AGENT_CONFIG_REFRESH_TOKEN" > "$token_file"
  fi

  [[ -n "$AGENT_CONFIG_REFRESH_TOKEN" ]] || _ac_err "Could not create agent config refresh token"
  chmod 600 "$token_file" 2>/dev/null || true
  export AGENT_CONFIG_REFRESH_TOKEN
}

# ══════════════════════════════════════════════════════════════════════════════
# apply_with_retry <plan_file> [terraform plan args...]
#
# Wrap `terraform apply` with up to 3 attempts, re-planning between retries,
# to survive transient Atlas API / saved-plan staleness errors.
# If the initial plan used targeted args, pass the same args after plan_file so
# retry re-plans the same scope instead of accidentally planning the full stack.
# ══════════════════════════════════════════════════════════════════════════════
apply_with_retry() {
  local plan_file="$1"
  shift || true
  local plan_args=("$@")
  local max_attempts=3
  local attempt=1
  local log_file rc
  log_file=$(mktemp -t tf-apply.XXXXXX)

  while (( attempt <= max_attempts )); do
    if (( attempt > 1 )); then
      _ac_log "Retry $((attempt - 1))/$((max_attempts - 1)) — sleeping 30s, then re-planning..."
      sleep 30
      if declare -F deploy_diag_checkpoint >/dev/null 2>&1; then
        deploy_diag_checkpoint "terraform retry plan attempt ${attempt}/${max_attempts}: terraform plan -input=false ${plan_args[*]} -out=${plan_file}"
      fi
      terraform plan -input=false "${plan_args[@]}" -out="$plan_file"
      _ac_ok "re-plan complete"
    fi
    _ac_log "Apply attempt ${attempt}/${max_attempts}..."
    if declare -F deploy_diag_checkpoint >/dev/null 2>&1; then
      deploy_diag_checkpoint "terraform apply attempt ${attempt}/${max_attempts}: terraform apply -input=false ${plan_file}"
    fi
    set +e
    terraform apply -input=false "$plan_file" 2>&1 | tee "$log_file"
    rc=${PIPESTATUS[0]}
    set -e
    if (( rc == 0 )); then
      rm -f "$log_file"
      return 0
    fi
    if grep -qE 'cloud\.mongodb\.com.*(i/o timeout|connection reset|connection refused|EOF|TLS handshake timeout)|Saved plan is stale' "$log_file"; then
      _ac_warn "Transient Terraform apply error on attempt ${attempt} — will retry"
      attempt=$((attempt + 1))
      continue
    fi
    rm -f "$log_file"
    _ac_err "terraform apply failed with a non-transient error (see output above)"
  done
  rm -f "$log_file"
  _ac_err "terraform apply failed after ${max_attempts} attempts"
}

# ══════════════════════════════════════════════════════════════════════════════
# discover_agents
#
# Scans config/agents/*.agent.md, parses YAML frontmatter with python3, and
# classifies id: orchestrator as the orchestrator; every other agent config is
# a specialist. Runtime handoffs are generated from this roster by the API.
#
# Sets globals:
#   AGENTS_JSON          — full JSON: {orchestrator:{id,runtimeName}, specialists:[{id,runtimeName}]}
#   ORCHESTRATOR_ID      — id of the orchestrator agent
#   SPECIALIST_IDS       — bash array of specialist ids (e.g. [troubleshooting order-management ...])
#   SPECIALIST_IDS_JSON  — JSON array string for the specialists list
# ══════════════════════════════════════════════════════════════════════════════
discover_agents() {
  local agents_dir="$REPO_ROOT/config/agents"
  [[ -d "$agents_dir" ]] || _ac_err "config/agents/ directory not found at $REPO_ROOT"

  AGENTS_JSON=$(python3 - "$agents_dir" "$PROJECT_NAME" "$ENVIRONMENT" <<'PYEOF'
import json, os, re, sys

agents_dir  = sys.argv[1]
project     = sys.argv[2]
environment = sys.argv[3]

def parse_frontmatter(path):
    """Return the YAML frontmatter block as a string, or '' if none."""
    with open(path) as f:
        content = f.read()
    m = re.match(r"^---\n(.*?)\n---", content, re.DOTALL)
    return m.group(1) if m else ""

def parse_yaml_simple(text):
    """
    Minimal YAML key-value parser (no third-party deps).
    Handles:
      key: scalar
      key:
        - item
      key: [inline list]
    Returns a dict with str keys; list values are list[str], scalars are str.
    """
    result = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r'^(\w[\w-]*):\s*(.*)', line)
        if not m:
            i += 1
            continue
        key, val = m.group(1), m.group(2).strip()
        if val.startswith('['):
            # inline list: key: [a, b, c]
            inner = re.sub(r'^\[|\]$', '', val)
            result[key] = [x.strip().strip("'\"") for x in inner.split(',') if x.strip()]
            i += 1
        elif val == '' or val is None:
            # possible block list on next lines
            items = []
            i += 1
            while i < len(lines) and re.match(r'^\s+-\s+', lines[i]):
                item_m = re.match(r'^\s+-\s+(.*)', lines[i])
                if item_m:
                    raw = item_m.group(1).strip().strip("'\"")
                    # handoff entries may be objects; grab 'agent:' value if present
                    agent_m = re.match(r'agent:\s*(\S+)', raw)
                    items.append(agent_m.group(1) if agent_m else raw)
                i += 1
            result[key] = items
        else:
            result[key] = val
            i += 1
    return result

orchestrator = None
specialists  = []

for fname in sorted(os.listdir(agents_dir)):
    if not fname.endswith('.agent.md'):
        continue
    path = os.path.join(agents_dir, fname)
    fm_text = parse_frontmatter(path)
    if not fm_text:
        continue
    fm = parse_yaml_simple(fm_text)
    agent_id = fm.get('id', fname.replace('.agent.md', ''))
    # runtime_name must match the existing naming convention so existing
    # AgentCore Runtime resources are not accidentally recreated.
    safe_name = re.sub(r'[^a-zA-Z0-9_]', '_', f"{project}_{agent_id}_{environment}")[:48]
    runtime_name = f"{project}-{agent_id}-{environment}"
    entry = {'id': agent_id, 'runtimeName': runtime_name, 'safeName': safe_name}
    if agent_id == 'orchestrator':
        orchestrator = entry
    else:
        specialists.append(entry)

if orchestrator is None:
    raise SystemExit("discover_agents: no orchestrator agent found in config/agents/. "
                     "An orchestrator must have id: orchestrator.")

print(json.dumps({'orchestrator': orchestrator, 'specialists': specialists}))
PYEOF
  ) || _ac_err "discover_agents: python3 parser failed"

  ORCHESTRATOR_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['orchestrator']['id'])" "$AGENTS_JSON")
  SPECIALIST_IDS_JSON=$(python3 -c "import json,sys; print(json.dumps([s['id'] for s in json.loads(sys.argv[1])['specialists']]))" "$AGENTS_JSON")

  # Populate bash array
  SPECIALIST_IDS=()
  while IFS= read -r sid; do
    SPECIALIST_IDS+=("$sid")
  done < <(python3 -c "import json,sys
for s in json.loads(sys.argv[1])['specialists']:
    print(s['id'])" "$AGENTS_JSON")

  _ac_ok "Discovered orchestrator: ${ORCHESTRATOR_ID}"
  _ac_ok "Discovered specialists: ${SPECIALIST_IDS[*]:-'(none)'}"
}

# ══════════════════════════════════════════════════════════════════════════════
# validate_handoff_consistency
#
# Backward-compatible guard for legacy orchestrator frontmatter that still has
# a handoffs: list. Current runtime routing generates handoffs from every
# non-orchestrator config/agents/*.agent.md file, so new agents do not require
# editing orchestrator.agent.md.
#
# Requires: AGENTS_JSON set by discover_agents
# Param:    $1 — "warn" to print and continue, "fail" (default) to exit
# ══════════════════════════════════════════════════════════════════════════════
validate_handoff_consistency() {
  local mode="${1:-fail}"
  local orchestrator_file="$REPO_ROOT/config/agents/orchestrator.agent.md"
  [[ -f "$orchestrator_file" ]] || return 0

  local bad_handoffs
  bad_handoffs=$(python3 - "$AGENTS_JSON" "$orchestrator_file" <<'PYEOF'
import json, re, sys

agents_json      = json.loads(sys.argv[1])
orchestrator_md  = sys.argv[2]
specialist_ids   = {s['id'] for s in agents_json['specialists']}

with open(orchestrator_md) as f:
    content = f.read()

m = re.match(r'^---\n(.*?)\n---', content, re.DOTALL)
fm_text = m.group(1) if m else ''

# Extract all "agent: <id>" lines inside the handoffs block
handoff_agents = re.findall(r'^\s+agent:\s+(\S+)', fm_text, re.MULTILINE)
stale = [a for a in handoff_agents if a not in specialist_ids]
if stale:
    print(' '.join(stale))
PYEOF
  )

  if [[ -n "$bad_handoffs" ]]; then
    if [[ "$mode" == "fail" ]]; then
      _ac_err "Orchestrator handoffs reference specialist(s) not found in config/agents/: ${bad_handoffs}
       Either restore the .agent.md file(s) or remove the handoffs entry from orchestrator.agent.md.
       Use --force to skip this check."
    else
      _ac_warn "Orchestrator handoffs reference missing specialists: ${bad_handoffs} (continuing due to --force)"
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# write_specialist_agents_tfvars
#
# Writes deploy/terraform/envs/ec2/agents.auto.tfvars.json from AGENTS_JSON.
# Terraform auto-loads *.auto.tfvars.json, so adding this file is enough to
# pass specialist_agents into the for_each without editing terraform.tfvars.
#
# Requires: AGENTS_JSON set by discover_agents, TF_DIR set by caller.
# ══════════════════════════════════════════════════════════════════════════════
write_specialist_agents_tfvars() {
  local tfvars_file="$TF_DIR/agents.auto.tfvars.json"
  python3 - "$AGENTS_JSON" > "$tfvars_file" <<'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
# Terraform variable shape: list(object({ id=string, runtime_name=string }))
specialists = [
    {'id': s['id'], 'runtime_name': s['runtimeName']}
    for s in data['specialists']
]
print(json.dumps({'specialist_agents': specialists}, indent=2))
PYEOF
  _ac_ok "Wrote agents.auto.tfvars.json (${#SPECIALIST_IDS[@]} specialist(s))"
}

# ══════════════════════════════════════════════════════════════════════════════
# build_and_upload_code_artifact
#
# Builds the AgentCore direct-code artifact (bun → JS → zip) and uploads it
# to S3. Skipped when AGENTCORE_RUNTIME_DEPLOYMENT_MODE == "container".
#
# Requires: REPO_ROOT, SHARED_BUCKET, AGENTCORE_CODE_ARTIFACT_PREFIX, AWS_REGION
# ══════════════════════════════════════════════════════════════════════════════
build_and_upload_code_artifact() {
  if [[ "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE" != "code" ]]; then
    _ac_log "Skipping code artifact build (deployment mode: ${AGENTCORE_RUNTIME_DEPLOYMENT_MODE})"
    return 0
  fi

  _ac_log "Building AgentCore direct-code artifact (TS → JS)..."
  if [[ -f "$REPO_ROOT/api/bun.lockb" || -f "$REPO_ROOT/api/bun.lock" ]]; then
    (cd "$REPO_ROOT/api" && bun install --frozen-lockfile)
  else
    (cd "$REPO_ROOT/api" && bun install)
  fi
  (cd "$REPO_ROOT/api" && bun run build:agentcore-code)

  local ARTIFACT_ZIP="$REPO_ROOT/api/dist/agentcore-deployment.zip"
  local ARTIFACT_STAGE_DIR="$REPO_ROOT/api/dist/agentcore-package"
  rm -f "$ARTIFACT_ZIP"
  rm -rf "$ARTIFACT_STAGE_DIR"
  mkdir -p "$ARTIFACT_STAGE_DIR/config"
  cp "$REPO_ROOT/api/dist/agent-runtime-code.js" "$ARTIFACT_STAGE_DIR/agent-runtime-code.js"
  cp -R "$REPO_ROOT/config/." "$ARTIFACT_STAGE_DIR/config/"
  (cd "$ARTIFACT_STAGE_DIR" && zip -r "../agentcore-deployment.zip" . >/dev/null)
  aws s3 cp "$ARTIFACT_ZIP" "s3://${SHARED_BUCKET}/${AGENTCORE_CODE_ARTIFACT_PREFIX}" --region "$AWS_REGION" >/dev/null
  _ac_ok "Uploaded code artifact → s3://${SHARED_BUCKET}/${AGENTCORE_CODE_ARTIFACT_PREFIX}"
}

# ══════════════════════════════════════════════════════════════════════════════
# build_dynamic_env_base
#
# Constructs the JSON env-vars map common to all runtimes (MongoDB, KB,
# gateway, memory, embeddings). Sets global DYNAMIC_ENV_BASE.
#
# Requires all the optional env vars listed at the top of this file.
# ══════════════════════════════════════════════════════════════════════════════
build_dynamic_env_base() {
  DYNAMIC_ENV_BASE=$(MONGODB_URI="${MONGODB_URI:-}" \
    ATLAS_DB_NAME="${ATLAS_DB_NAME:-}" \
    BEDROCK_KB_ID="${BEDROCK_KB_ID:-}" \
    AGENTCORE_MEMORY_STORE_ID="${AGENTCORE_MEMORY_STORE_ID:-}" \
    AGENTCORE_GATEWAY_URL="${AGENTCORE_GATEWAY_URL:-}" \
    MONGODB_MCP_RUNTIME_ARN="${MONGODB_MCP_RUNTIME_ARN:-}" \
    MONGODB_MCP_RUNTIME_ENDPOINT="${MONGODB_MCP_RUNTIME_ENDPOINT:-}" \
    VOYAGE_ENDPOINT="${VOYAGE_ENDPOINT:-}" \
    MEMORY_TRACE_VALUES="${MEMORY_TRACE_VALUES:-0}" \
    TRACE_PROMPT_BODY="${TRACE_PROMPT_BODY:-0}" \
    TRACE_REDACT="${TRACE_REDACT:-0}" \
    python3 -c "
import json, os
env = {
  'AWS_REGION':                os.environ.get('AWS_REGION', ''),
  'SHORT_TERM_MEMORY_BACKEND': 'agentcore',
  'PERSIST_CHAT_SESSIONS':     '1',
  'MEMORY_TTL_DAYS':           '30',
  'LOG_LEVEL':                 'info',
  'MONGODB_URI':               os.environ.get('MONGODB_URI', ''),
  'MONGODB_DB':                os.environ.get('ATLAS_DB_NAME', ''),
  'BEDROCK_KB_ID':             os.environ.get('BEDROCK_KB_ID', ''),
  'AGENTCORE_MEMORY_STORE_ID': os.environ.get('AGENTCORE_MEMORY_STORE_ID', ''),
  'MCP_SERVER_URL':            os.environ.get('AGENTCORE_GATEWAY_URL', ''),
  'AGENTCORE_GATEWAY_URL':     os.environ.get('AGENTCORE_GATEWAY_URL', ''),
  'MONGODB_MCP_RUNTIME_ARN':   os.environ.get('MONGODB_MCP_RUNTIME_ARN', ''),
  'MONGODB_MCP_RUNTIME_ENDPOINT': os.environ.get('MONGODB_MCP_RUNTIME_ENDPOINT', ''),
  'EMBEDDING_MODEL_ID':        'amazon.titan-embed-text-v2:0',
  'EMBEDDINGS_PROVIDER':       os.environ.get('EMBEDDINGS_PROVIDER', ''),
  'VOYAGE_SAGEMAKER_ENDPOINT': os.environ.get('VOYAGE_ENDPOINT', ''),
  'VOYAGE_OUTPUT_DIM':         '1024',
  'VOYAGE_REQUEST_FORMAT':     os.environ.get('VOYAGE_REQUEST_FORMAT', 'multimodal'),
  # LTM trace-value gating — sourced from operator .env so flips are
  # captured by ./deploy/deploy-agents.sh and never hand-edited on EC2.
  # 0 (default) = redacted; 1 = raw text in trace events.
  'MEMORY_TRACE_VALUES':       os.environ.get('MEMORY_TRACE_VALUES', '0'),
  'TRACE_PROMPT_BODY':         os.environ.get('TRACE_PROMPT_BODY', '0'),
  'TRACE_REDACT':              os.environ.get('TRACE_REDACT', '0'),
}
print(json.dumps({k: str(v) for k, v in env.items() if v}))
")
}

# ══════════════════════════════════════════════════════════════════════════════
# update_runtime_env_dynamic
#
# Calls update-agent-runtime for every specialist (base env + AGENT_ID) and
# for the orchestrator (base env + ORCHESTRATOR_MODE + all specialist ARNs).
# Also bumps the code artifact pointer so AgentCore picks up the new S3 object.
#
# Requires:
#   DYNAMIC_ENV_BASE        (set by build_dynamic_env_base)
#   AGENTS_JSON             (set by discover_agents)
#   SPECIALIST_IDS          bash array
#   AGENTCORE_ORCHESTRATOR_ID
#   AGENTCORE_ORCHESTRATOR_ARN
#   SPECIALIST_RUNTIME_IDS_JSON   JSON map id→runtime_id  (built below)
#   SPECIALIST_RUNTIME_ARNS_JSON  JSON map id→runtime_arn (built below)
#   AWS_REGION, SHARED_BUCKET, AGENTCORE_CODE_ARTIFACT_PREFIX
#   AGENTCORE_RUNTIME_DEPLOYMENT_MODE
#   ECR_RUNTIME_REPO        (only when deployment mode = container)
# ══════════════════════════════════════════════════════════════════════════════
update_runtime_env_dynamic() {
  local ECR_RUNTIME_IMAGE="${ECR_RUNTIME_REPO:+${ECR_RUNTIME_REPO}:latest}"

  _update_single_runtime() {
    local runtime_id="$1"
    local env_json="$2"
    local runtime_label="$3"

    local role_arn
    role_arn=$(aws bedrock-agentcore-control get-agent-runtime \
      --region "$AWS_REGION" \
      --agent-runtime-id "$runtime_id" \
      --query "roleArn" --output text 2>/dev/null || echo "")
    if [[ -z "$role_arn" || "$role_arn" == "None" ]]; then
      _ac_err "Could not resolve roleArn for ${runtime_label} (${runtime_id})"
    fi

    if [[ "$AGENTCORE_RUNTIME_DEPLOYMENT_MODE" == "container" ]]; then
      aws bedrock-agentcore-control update-agent-runtime \
        --region "$AWS_REGION" \
        --agent-runtime-id "$runtime_id" \
        --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_RUNTIME_IMAGE}\"}}" \
        --role-arn "$role_arn" \
        --network-configuration '{"networkMode":"PUBLIC"}' \
        --environment-variables "$env_json" \
        --output json > /dev/null 2>&1 \
        && _ac_ok "Updated ${runtime_label} runtime env vars" \
        || _ac_err "Failed to update ${runtime_label} runtime env vars"
    else
      aws bedrock-agentcore-control update-agent-runtime \
        --region "$AWS_REGION" \
        --agent-runtime-id "$runtime_id" \
        --agent-runtime-artifact "{\"codeConfiguration\":{\"code\":{\"s3\":{\"bucket\":\"${SHARED_BUCKET}\",\"prefix\":\"${AGENTCORE_CODE_ARTIFACT_PREFIX}\"}},\"runtime\":\"NODE_22\",\"entryPoint\":[\"agent-runtime-code.js\"]}}" \
        --role-arn "$role_arn" \
        --network-configuration '{"networkMode":"PUBLIC"}' \
        --environment-variables "$env_json" \
        --output json > /dev/null 2>&1 \
        && _ac_ok "Updated ${runtime_label} runtime env vars + code artifact" \
        || _ac_err "Failed to update ${runtime_label} runtime env vars/code artifact"
    fi
  }

  # Update each specialist runtime.
  for spec_id in "${SPECIALIST_IDS[@]:-}"; do
    local spec_runtime_id
    spec_runtime_id="$(specialist_runtime_id "$spec_id")"
    [[ -n "$spec_runtime_id" && "$spec_runtime_id" != "None" ]] || continue
    local spec_env
    spec_env=$(DYNAMIC_ENV_BASE="$DYNAMIC_ENV_BASE" python3 -c "
import json, os, sys
env = json.loads(os.environ['DYNAMIC_ENV_BASE'])
env['AGENT_ID'] = sys.argv[1]
print(json.dumps(env))" "$spec_id")
    _update_single_runtime "$spec_runtime_id" "$spec_env" "$spec_id"
  done

  # Build orchestrator env: base + ORCHESTRATOR_MODE + per-specialist ARNs.
  local orch_env
  orch_env=$(DYNAMIC_ENV_BASE="$DYNAMIC_ENV_BASE" \
    SPECIALIST_ARNS_JSON="$(python3 -c "
import json, sys
arns = {}
for spec_id, spec_arn in zip(sys.argv[1].split(','), sys.argv[2].split(',')):
    if spec_id and spec_arn:
        upper = spec_id.upper().replace('-', '_')
        arns[f'AGENTCORE_RUNTIME_ARN_{upper}'] = spec_arn
print(json.dumps(arns))" \
      "$(IFS=,; echo "${SPECIALIST_IDS[*]:-}")" \
      "$(for spec_id in "${SPECIALIST_IDS[@]:-}"; do printf '%s,' "$(specialist_runtime_arn "$spec_id")"; done | sed 's/,$//')")" \
    python3 -c "
import json, os
env = json.loads(os.environ['DYNAMIC_ENV_BASE'])
env['AGENT_ID']         = 'orchestrator'
env['ORCHESTRATOR_MODE'] = 'runtime'
arns = json.loads(os.environ.get('SPECIALIST_ARNS_JSON', '{}'))
for k, v in arns.items():
    if v:
        env[k] = v
print(json.dumps(env))")

  _update_single_runtime "$AGENTCORE_ORCHESTRATOR_ID" "$orch_env" "orchestrator"
}

# ══════════════════════════════════════════════════════════════════════════════
# verify_runtime_env_dynamic
#
# Polls each runtime (up to 12 × 5s) until environment variables are stable,
# then asserts the expected values. Exits on first failure.
#
# Requires same globals as update_runtime_env_dynamic.
# ══════════════════════════════════════════════════════════════════════════════
verify_runtime_env_dynamic() {
  _verify_single_runtime() {
    local runtime_id="$1"
    local runtime_label="$2"
    local expected_agent_id="$3"
    local is_orchestrator="$4"   # "yes" or "no"
    local attempt env_json

    for attempt in $(seq 1 12); do
      env_json=$(aws bedrock-agentcore-control get-agent-runtime \
        --region "$AWS_REGION" \
        --agent-runtime-id "$runtime_id" \
        --query "environmentVariables" \
        --output json 2>/dev/null || echo "{}")

      if python3 - <<'PYEOF' "$env_json" "$runtime_label" "$expected_agent_id" "$is_orchestrator" \
          "${AGENTCORE_GATEWAY_URL:-}" "${MONGODB_MCP_RUNTIME_ARN:-}" "${MONGODB_MCP_RUNTIME_ENDPOINT:-}" \
          "${SPECIALIST_IDS_JSON:-[]}"
import json, sys
env            = json.loads(sys.argv[1] or "{}")
label          = sys.argv[2]
expected_agent = sys.argv[3]
is_orch        = sys.argv[4] == "yes"
expected_gw    = sys.argv[5]
expected_mcp_arn  = sys.argv[6]
expected_mcp_ep   = sys.argv[7]
specialist_ids = json.loads(sys.argv[8])

def fail(msg):
    raise SystemExit(f"{label}: {msg}")

if env.get("AGENT_ID") != expected_agent:
    fail(f"AGENT_ID expected '{expected_agent}', got '{env.get('AGENT_ID')}'")
if not env.get("MCP_SERVER_URL"):
    fail("MCP_SERVER_URL missing")
if expected_gw and env.get("MCP_SERVER_URL") != expected_gw:
    fail(f"MCP_SERVER_URL mismatch (got '{env.get('MCP_SERVER_URL')}', want '{expected_gw}')")
if expected_mcp_arn and env.get("MONGODB_MCP_RUNTIME_ARN") != expected_mcp_arn:
    fail("MONGODB_MCP_RUNTIME_ARN missing or mismatched")
if expected_mcp_ep and env.get("MONGODB_MCP_RUNTIME_ENDPOINT") != expected_mcp_ep:
    fail("MONGODB_MCP_RUNTIME_ENDPOINT missing or mismatched")
if env.get("SHORT_TERM_MEMORY_BACKEND") != "agentcore":
    fail(f"SHORT_TERM_MEMORY_BACKEND expected 'agentcore', got '{env.get('SHORT_TERM_MEMORY_BACKEND')}'")
if is_orch:
    if env.get("ORCHESTRATOR_MODE") != "runtime":
        fail(f"ORCHESTRATOR_MODE expected 'runtime', got '{env.get('ORCHESTRATOR_MODE')}'")
    for spec_id in specialist_ids:
        upper = spec_id.upper().replace('-', '_')
        key   = f"AGENTCORE_RUNTIME_ARN_{upper}"
        if not env.get(key):
            fail(f"{key} missing on orchestrator")
print("ok")
PYEOF
      then
        return 0
      fi
      sleep 5
    done
    return 1
  }

  for spec_id in "${SPECIALIST_IDS[@]:-}"; do
    local spec_runtime_id
    spec_runtime_id="$(specialist_runtime_id "$spec_id")"
    [[ -n "$spec_runtime_id" && "$spec_runtime_id" != "None" ]] || continue
    _verify_single_runtime "$spec_runtime_id" "$spec_id" "$spec_id" "no" \
      || _ac_err "Runtime env verification failed for $spec_id"
  done

  _verify_single_runtime "$AGENTCORE_ORCHESTRATOR_ID" "orchestrator" "orchestrator" "yes" \
    || _ac_err "Runtime env verification failed for orchestrator"

  _ac_ok "Runtime env verification passed for all runtimes"
}

# ══════════════════════════════════════════════════════════════════════════════
# load_specialist_outputs_from_tf
#
# Reads acr_specialist_arns and acr_specialist_ids from terraform output (JSON
# maps) and stores them as JSON globals. Use specialist_runtime_arn <id> and
# specialist_runtime_id <id> instead of Bash associative arrays so the scripts
# work with macOS Bash 3.2.
#
# Must be called from inside the TF_DIR working directory (after terraform init).
# ══════════════════════════════════════════════════════════════════════════════
load_specialist_outputs_from_tf() {
  SPECIALIST_RUNTIME_ARNS_JSON=$(terraform output -json acr_specialist_arns 2>/dev/null || echo "{}")
  SPECIALIST_RUNTIME_IDS_JSON=$(terraform output -json acr_specialist_ids 2>/dev/null || echo "{}")
}

specialist_runtime_arn() {
  local spec_id="$1"
  python3 -c "import json,sys; print(json.loads(sys.argv[1] or '{}').get(sys.argv[2], ''))" \
    "${SPECIALIST_RUNTIME_ARNS_JSON:-}" "$spec_id"
}

specialist_runtime_id() {
  local spec_id="$1"
  python3 -c "import json,sys; print(json.loads(sys.argv[1] or '{}').get(sys.argv[2], ''))" \
    "${SPECIALIST_RUNTIME_IDS_JSON:-}" "$spec_id"
}
