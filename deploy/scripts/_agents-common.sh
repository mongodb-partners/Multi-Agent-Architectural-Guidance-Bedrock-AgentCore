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
#   AGENTCORE_GATEWAY_URL,
#   VOYAGE_ENDPOINT, EMBEDDINGS_PROVIDER
#
# Functions exported by this file:
#   apply_with_retry <plan_file> [terraform plan args...]
#   discover_agents              → sets AGENTS_JSON, ORCHESTRATOR_ID, SPECIALIST_IDS[]
#   write_specialist_agents_tfvars
#   validate_handoff_consistency
#   build_and_upload_code_artifact
#   build_dynamic_env_base      → sets DYNAMIC_ENV_BASE
#   update_runtime_env_dynamic
#   update_mcp_runtime_mongodb_env
#   verify_runtime_env_dynamic
#   ensure_agent_config_refresh_token
#   force_mcp_runtime_image_sync
#   self_heal_failed_gateway_target
#   warm_mcp_runtime

# ─── Guard ────────────────────────────────────────────────────────────────────
# Prevent double-sourcing.
[[ -n "${_AGENTS_COMMON_SOURCED:-}" ]] && return 0
_AGENTS_COMMON_SOURCED=1

# Shared transient-error classifier (DNS resolver + network/transport blips).
# Resolve relative to THIS file, not the caller's SCRIPT_DIR (callers vary).
# shellcheck source=deploy/scripts/_transient-errors.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_transient-errors.sh"

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
    # Transient = local DNS resolver / network blip (shared classifier) OR
    # Terraform saved-plan staleness after state changed between plan and apply.
    if deploy_log_has_transient_error "$log_file" \
       || grep -qE 'Saved plan is stale' "$log_file"; then
      _ac_warn "Transient Terraform apply error on attempt ${attempt} — will re-plan and retry"
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
test_only_agent_ids = {"http-tool-test"}

for fname in sorted(os.listdir(agents_dir)):
    if not fname.endswith('.agent.md'):
        continue
    path = os.path.join(agents_dir, fname)
    fm_text = parse_frontmatter(path)
    if not fm_text:
        continue
    fm = parse_yaml_simple(fm_text)
    agent_id = fm.get('id', fname.replace('.agent.md', ''))
    if agent_id in test_only_agent_ids:
        # Kept under config/agents for local/schema exercises only. It is not
        # one of the deployed AgentCore specialist runtimes.
        continue
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
    AWS_REGION="${AWS_REGION:-}" \
    EMBEDDING_MODEL_ID="${EMBEDDING_MODEL_ID:-}" \
    EMBEDDINGS_PROVIDER="${EMBEDDINGS_PROVIDER:-}" \
    VOYAGE_ENDPOINT="${VOYAGE_ENDPOINT:-}" \
    MEMORY_TRACE_VALUES="${MEMORY_TRACE_VALUES:-0}" \
    TRACE_PROMPT_BODY="${TRACE_PROMPT_BODY:-0}" \
    TRACE_REDACT="${TRACE_REDACT:-0}" \
    python3 - <<'PYEOF'
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
  'AGENTCORE_GATEWAY_URL':     os.environ.get('AGENTCORE_GATEWAY_URL', ''),
  # Strict-mode embeddings: only emit EMBEDDING_MODEL_ID when the bash side
  # explicitly exports it (titan stacks). The Python `if v` filter at the
  # bottom of this heredoc drops empty values, so voyage stacks never leak
  # a Bedrock fallback model id into AgentCore runtimes.
  'EMBEDDING_MODEL_ID':        os.environ.get('EMBEDDING_MODEL_ID', ''),
  'EMBEDDINGS_PROVIDER':       os.environ.get('EMBEDDINGS_PROVIDER', ''),
  'VOYAGE_SAGEMAKER_ENDPOINT': os.environ.get('VOYAGE_ENDPOINT', ''),
  # Voyage configuration is intentionally minimal here. The runtime adapter
  # (api/src/adapters/voyage-embedding.ts) owns the canonical multimodal
  # envelope and resolves VOYAGE_OUTPUT_DIM (default 1024). The legacy
  # text-only envelope and request-format override were removed in the
  # multimodal-only migration — see docs/reference/voyage.md.
  'VOYAGE_OUTPUT_DIM':         os.environ.get('VOYAGE_OUTPUT_DIM', ''),
  # LTM trace-value gating — sourced from operator .env so flips are
  # captured by ./deploy/deploy-agents.sh and never hand-edited on EC2.
  # 0 (default) = redacted; 1 = raw text in trace events.
  'MEMORY_TRACE_VALUES':       os.environ.get('MEMORY_TRACE_VALUES', '0'),
  'TRACE_PROMPT_BODY':         os.environ.get('TRACE_PROMPT_BODY', '0'),
  'TRACE_REDACT':              os.environ.get('TRACE_REDACT', '0'),
}
print(json.dumps({k: str(v) for k, v in env.items() if v}))
PYEOF
)
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
# update_mcp_runtime_mongodb_env
#
# Terraform bakes a mode-aware MONGODB_URI into the mongodb-mcp container runtime
# at apply time. Phase 5c then normalizes the API URI (retryWrites, PL flags).
# This helper re-syncs the MCP runtime env to the same URI the API uses so
# pf_check_mcp_runtime_env_complete and /health/deep see identical connection
# strings. Preserves all other runtime env vars and container config. Also
# re-syncs MONGODB_ALLOW_WRITE because existing AgentCore runtimes intentionally
# ignore Terraform environment-variable drift and rely on this phase for live
# runtime env updates.
#
# Args:
#   $1 runtime_id   mongodb-mcp AgentCore runtime id
#   $2 mongodb_uri   same MONGODB_URI written to .env.live (post Phase 5c)
#   $3 mongodb_db    ATLAS_DB_NAME
# ══════════════════════════════════════════════════════════════════════════════
update_mcp_runtime_mongodb_env() {
  local runtime_id="$1"
  local mongodb_uri="$2"
  local mongodb_db="$3"

  if [[ -z "$runtime_id" || "$runtime_id" == "None" ]]; then
    _ac_warn "update_mcp_runtime_mongodb_env: empty runtime_id — skipping"
    return 0
  fi
  [[ -n "$mongodb_uri" ]] || _ac_err "update_mcp_runtime_mongodb_env: empty mongodb_uri"
  [[ -n "$mongodb_db" ]] || _ac_err "update_mcp_runtime_mongodb_env: empty mongodb_db"

  local cfg_json
  cfg_json=$(aws bedrock-agentcore-control get-agent-runtime \
    --region "$AWS_REGION" \
    --agent-runtime-id "$runtime_id" \
    --output json 2>/dev/null || echo "")
  if [[ -z "$cfg_json" ]]; then
    _ac_err "update_mcp_runtime_mongodb_env: get-agent-runtime returned empty for ${runtime_id}"
  fi

  local update_args_file update_err
  update_args_file=$(mktemp -t mcp-mongo-env.XXXXXX.json)
  CFG_JSON="$cfg_json" \
  RUNTIME_ID="$runtime_id" \
  MONGO_URI="$mongodb_uri" \
  MONGO_DB="$mongodb_db" \
  MONGO_ALLOW_WRITE="${MONGODB_ALLOW_WRITE:-${TF_VAR_mongodb_allow_write:-}}" \
  python3 - <<'PY' > "$update_args_file"
import json, os

cfg = json.loads(os.environ["CFG_JSON"])
env = dict(cfg.get("environmentVariables") or {})
env["MONGODB_URI"] = os.environ["MONGO_URI"]
env["MONGODB_DB"] = os.environ["MONGO_DB"]
allow_write_raw = os.environ.get("MONGO_ALLOW_WRITE", "")
allow_write = allow_write_raw.strip().lower() in {"1", "true", "yes", "on"}
env["MONGODB_ALLOW_WRITE"] = "1" if allow_write else "0"
out = {
    "agentRuntimeId": os.environ["RUNTIME_ID"],
    "roleArn": cfg["roleArn"],
    "agentRuntimeArtifact": cfg["agentRuntimeArtifact"],
    "networkConfiguration": cfg.get("networkConfiguration") or {"networkMode": "PUBLIC"},
    "protocolConfiguration": cfg.get("protocolConfiguration") or {"serverProtocol": "MCP"},
    "environmentVariables": env,
}
for key in ("lifecycleConfiguration", "description", "authorizerConfiguration"):
    if cfg.get(key) is not None:
        out[key] = cfg[key]
print(json.dumps(out))
PY

  if ! update_err=$(aws bedrock-agentcore-control update-agent-runtime \
    --region "$AWS_REGION" \
    --cli-input-json "file://${update_args_file}" \
    --output json 2>&1); then
    rm -f "$update_args_file"
    echo "$update_err" >&2
    _ac_err "mongodb-mcp runtime ${runtime_id}: update-agent-runtime (MONGODB_URI) failed"
  fi
  rm -f "$update_args_file"
  _ac_ok "mongodb-mcp runtime env synced (MONGODB_URI + MONGODB_DB + MONGODB_ALLOW_WRITE)"

  local runtime_status attempt
  for attempt in $(seq 1 36); do
    runtime_status=$(aws bedrock-agentcore-control get-agent-runtime \
      --region "$AWS_REGION" \
      --agent-runtime-id "$runtime_id" \
      --query "status" --output text 2>/dev/null || echo "UNKNOWN")
    if [[ "$runtime_status" == "READY" ]]; then
      _ac_ok "mongodb-mcp runtime ${runtime_id}: READY after env sync (attempt ${attempt})"
      return 0
    fi
    [[ $attempt -eq 36 ]] && _ac_warn "mongodb-mcp runtime ${runtime_id}: still ${runtime_status} after env sync — continuing"
    sleep 5
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# warm_mcp_runtime <runtime_arn> [warmup_invocations]
#
# Pre-warm an AgentCore Runtime MCP container by issuing direct
# `invoke-agent-runtime` MCP `initialize` calls. This avoids the cold-start
# race that lands the AgentCore Gateway target in status=FAILED:
#
#   1. Operator runs `create-gateway-target` (or TF null_resource does it).
#   2. The Gateway immediately probes the target via MCP `tools/list`.
#   3. AgentCore Runtime status=READY ≠ "warm container exists". If no
#      container is in the pool, AgentCore cold-starts one (~20-40s).
#   4. The Gateway probe times out (10-15s ceiling) → target = FAILED with
#      "Unable to connect to the MCP server" even though the container is
#      perfectly healthy and reachable seconds later.
#
# Empirically (docs/status/debugging.md "AgentCore Gateway target FAILED with
# cold-start race"), 2-3 warm invocations are enough — they fill the runtime
# pool with containers that respond inside the Gateway's probe window for
# `idleRuntimeSessionTimeout` (default 900s / 15 min).
#
# Each invocation uses a NEW `mcp-session-id` so AgentCore allocates a
# distinct container slot in the pool. Errors are non-fatal: the helper logs
# warnings and returns success, because warmup is best-effort — the subsequent
# Gateway probe will surface any real connectivity problems.
#
# Args:
#   $1 runtime_arn          Full AgentCore runtime ARN (required).
#   $2 warmup_count         Number of warmup invocations (default 3, or
#                           $MCP_WARMUP_INVOCATIONS env var).
#
# Skip with: MCP_RUNTIME_WARMUP=0 (incident-response only).
# ══════════════════════════════════════════════════════════════════════════════
warm_mcp_runtime() {
  local runtime_arn="$1"
  local warmup_count="${2:-${MCP_WARMUP_INVOCATIONS:-3}}"
  local region="${AWS_REGION:-us-east-1}"

  if [[ "${MCP_RUNTIME_WARMUP:-1}" != "1" ]]; then
    _ac_warn "MCP_RUNTIME_WARMUP=0 — skipping MCP runtime warmup (gateway target FAILED risk on cold start)"
    return 0
  fi

  if [[ -z "$runtime_arn" || "$runtime_arn" == "None" ]]; then
    _ac_warn "warm_mcp_runtime: empty runtime_arn — skipping"
    return 0
  fi

  _ac_log "warm_mcp_runtime: pre-warming ${runtime_arn##*/} with ${warmup_count} invocation(s) to avoid Gateway cold-start race"

  local i tmpfile status_code success=0
  for i in $(seq 1 "$warmup_count"); do
    tmpfile=$(mktemp -t mcp-warmup.XXXXXX.bin)
    # MCP `initialize` is the lightest valid JSON-RPC request that exercises
    # the full request → container → response path. We deliberately use
    # `cli-binary-format raw-in-base64-out` because the AWS CLI defaults to
    # base64-decoding `--payload` otherwise (rejecting our JSON literal as
    # "Invalid base64").
    if status_code=$(aws bedrock-agentcore invoke-agent-runtime \
        --region "$region" \
        --agent-runtime-arn "$runtime_arn" \
        --qualifier DEFAULT \
        --mcp-session-id "deploy-warmup-${i}-$(date +%s)-$$" \
        --mcp-protocol-version "2025-06-18" \
        --content-type "application/json" \
        --accept "application/json, text/event-stream" \
        --payload '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"deploy-warmup","version":"1.0"}}}' \
        --cli-binary-format raw-in-base64-out \
        "$tmpfile" 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("statusCode",""))' 2>/dev/null); then
      if [[ "$status_code" == "200" ]]; then
        success=$(( success + 1 ))
        _ac_log "warm_mcp_runtime: invocation ${i}/${warmup_count} → statusCode=200"
      else
        _ac_warn "warm_mcp_runtime: invocation ${i}/${warmup_count} → statusCode=${status_code:-?}"
      fi
    else
      _ac_warn "warm_mcp_runtime: invocation ${i}/${warmup_count} failed (CLI error) — continuing"
    fi
    rm -f "$tmpfile"
  done

  if (( success > 0 )); then
    _ac_ok "warm_mcp_runtime: ${success}/${warmup_count} warm invocations succeeded — runtime pool warm for ~15min"
  else
    _ac_warn "warm_mcp_runtime: 0/${warmup_count} warm invocations succeeded — gateway target may still hit cold-start race"
  fi
  return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# force_mcp_runtime_image_sync
#
# Container-mode AgentCore runtimes are wired to `<repo>:latest` in Terraform.
# After a fresh `docker push <repo>:latest`, the `:latest` tag points at a new
# digest but the Terraform-managed `container_uri` string is unchanged — so
# `terraform plan` shows no diff, the runtime resource is not replaced, and
# AgentCore never re-pulls the image. This is a silent freeze that has bitten
# us more than once (docs/status/debugging.md "AgentCore Runtime image push does not
# auto-trigger a runtime version bump").
#
# This helper:
#   1. Resolves the runtime's currently-deployed image digest (best effort) and
#      compares with the digest just pushed to ECR for the matching tag.
#   2. If they differ, calls update-agent-runtime preserving role/network/
#      protocol/env/lifecycle config — AgentCore treats every update as a new
#      version, which forces a fresh pull of :latest on the next cold start.
#   3. Waits for the runtime to reach READY.
#   4. Deletes any gateway target whose `triggers.endpoint` references this
#      runtime, so the next `terraform apply` recreates it (which re-runs
#      tools/list against the new container and refreshes the gateway's cached
#      tool schemas — see docs/status/debugging.md "AgentCore Gateway target caches
#      tool schemas — refresh after MCP runtime change").
#
# Skip with: MCP_RUNTIME_FORCE_SYNC=0 (incident-response only).
#
# Args:
#   $1 runtime_id          AgentCore runtime id (last component of the ARN)
#   $2 ecr_repo_name       e.g. "myproj-mongodb-mcp-dev"
#   $3 image_tag           e.g. "latest"
#   $4 gateway_id          gateway id whose target points at this runtime
#                          (pass "" to skip the gateway-target refresh step)
#   $5 gateway_target_name e.g. "mongodb-mcp" (only used when $4 is set)
#
# Related helper: `self_heal_failed_gateway_target` (below) is the right tool
# for the *post-apply smoke phase* when a target is already FAILED — it
# recreates the target inline via AWS CLI (no terraform apply available),
# whereas this helper deletes + relies on a subsequent terraform apply to
# recreate. The two helpers intentionally do not chain.
# ══════════════════════════════════════════════════════════════════════════════
force_mcp_runtime_image_sync() {
  local runtime_id="$1"
  local repo_name="$2"
  local image_tag="${3:-latest}"
  local gateway_id="${4:-}"
  local target_name="${5:-mongodb-mcp}"

  if [[ "${MCP_RUNTIME_FORCE_SYNC:-1}" != "1" ]]; then
    _ac_warn "MCP_RUNTIME_FORCE_SYNC=0 — skipping MCP runtime force-sync (image push will only land on next replace)"
    return 0
  fi

  if [[ -z "$runtime_id" || "$runtime_id" == "None" ]]; then
    _ac_warn "force_mcp_runtime_image_sync: empty runtime_id — first deploy, skipping (TF apply will create the runtime with the new image)"
    return 0
  fi

  # Pushed digest (just-now `docker push`).
  local pushed_digest
  pushed_digest=$(aws ecr describe-images \
    --region "$AWS_REGION" \
    --repository-name "$repo_name" \
    --image-ids "imageTag=${image_tag}" \
    --query 'imageDetails[0].imageDigest' \
    --output text 2>/dev/null || echo "")
  if [[ -z "$pushed_digest" || "$pushed_digest" == "None" ]]; then
    _ac_warn "force_mcp_runtime_image_sync: cannot resolve digest for ${repo_name}:${image_tag} — skipping force-sync (deploy will continue)"
    return 0
  fi

  # Current runtime config — we re-apply the same fields with `update-agent-runtime`
  # so AgentCore promotes a new version that will pull :latest on next cold start.
  local cfg_json
  cfg_json=$(aws bedrock-agentcore-control get-agent-runtime \
    --region "$AWS_REGION" \
    --agent-runtime-id "$runtime_id" \
    --output json 2>/dev/null || echo "")
  if [[ -z "$cfg_json" ]]; then
    _ac_warn "force_mcp_runtime_image_sync: get-agent-runtime returned empty for ${runtime_id} — skipping"
    return 0
  fi

  # The currentlyDeployedImage is not always exposed by the control plane;
  # when we can't compare, force-update unconditionally (cheap and safe — it
  # just bumps the version pointer; the actual pull is deferred to cold start).
  local current_uri changed
  current_uri=$(echo "$cfg_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
artifact = d.get('agentRuntimeArtifact') or {}
print((artifact.get('containerConfiguration') or {}).get('containerUri') or '')
")
  # `:latest` URI gives no digest signal — always force when running through this helper.
  changed="yes"
  _ac_log "force_mcp_runtime_image_sync: pushed digest ${pushed_digest:0:19}… on tag '${image_tag}' (current URI: ${current_uri:-unknown}) — forcing runtime version bump"

  if [[ "$changed" != "yes" ]]; then
    _ac_ok "MCP runtime already on the pushed digest — no version bump needed"
    return 0
  fi

  # Replay the runtime config on update-agent-runtime to mint a new version.
  # We preserve role/network/protocol/env/lifecycle so behaviour is unchanged
  # apart from the new container version.
  local update_args_file update_err
  update_args_file=$(mktemp -t mcp-update.XXXXXX.json)
  CFG_JSON="$cfg_json" \
  RUNTIME_ID="$runtime_id" \
  python3 - <<'PY' > "$update_args_file"
import json, os, sys

cfg = json.loads(os.environ['CFG_JSON'])
out = {
    'agentRuntimeId':     os.environ['RUNTIME_ID'],
    'roleArn':            cfg['roleArn'],
    'agentRuntimeArtifact': cfg['agentRuntimeArtifact'],
    'networkConfiguration':  cfg.get('networkConfiguration')  or {'networkMode': 'PUBLIC'},
    'protocolConfiguration': cfg.get('protocolConfiguration') or {'serverProtocol': 'MCP'},
    'environmentVariables':  cfg.get('environmentVariables', {}),
}
# Optional fields — only include when present so we don't reset to defaults.
for key in ('lifecycleConfiguration', 'description', 'authorizerConfiguration'):
    if cfg.get(key) is not None:
        out[key] = cfg[key]
print(json.dumps(out))
PY

  # Use a real file path — piping JSON to `file:///dev/stdin` fails on macOS
  # (aws-cli ParamValidation: Invalid JSON received) even though Linux accepts it.
  if ! update_err=$(aws bedrock-agentcore-control update-agent-runtime \
    --region "$AWS_REGION" \
    --cli-input-json "file://${update_args_file}" \
    --output json 2>&1); then
    rm -f "$update_args_file"
    echo "$update_err" >&2
    _ac_err "MCP runtime ${runtime_id}: update-agent-runtime failed"
  fi
  rm -f "$update_args_file"
  _ac_ok "MCP runtime ${runtime_id}: version bumped (will pull :latest on next cold start)"

  # Poll until READY (max ~3 min). Use runtime_status — zsh reserves `status`.
  local runtime_status attempt
  for attempt in $(seq 1 36); do
    runtime_status=$(aws bedrock-agentcore-control get-agent-runtime \
      --region "$AWS_REGION" \
      --agent-runtime-id "$runtime_id" \
      --query "status" --output text 2>/dev/null || echo "UNKNOWN")
    if [[ "$runtime_status" == "READY" ]]; then
      _ac_ok "MCP runtime ${runtime_id}: status=READY (attempt ${attempt})"
      break
    fi
    [[ $attempt -eq 36 ]] && _ac_warn "MCP runtime ${runtime_id}: still ${runtime_status} after ~3min — continuing anyway"
    sleep 5
  done

  if [[ -z "$gateway_id" ]]; then
    _ac_log "force_mcp_runtime_image_sync: no gateway_id passed — skipping target refresh"
    return 0
  fi

  # Pre-warm the runtime BEFORE deleting the gateway target. Without this,
  # the next `terraform apply` recreates the target against a cold runtime
  # (status=READY but no container in the pool); the gateway probe times
  # out and the target lands FAILED. See docs/status/debugging.md
  # "AgentCore Gateway target FAILED with cold-start race".
  local runtime_arn
  runtime_arn=$(echo "$cfg_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("agentRuntimeArn", ""))
' 2>/dev/null || echo "")
  if [[ -n "$runtime_arn" && "$runtime_arn" != "None" ]]; then
    warm_mcp_runtime "$runtime_arn"
  else
    _ac_warn "force_mcp_runtime_image_sync: could not resolve runtime ARN for warmup — gateway target may hit cold-start race on recreate"
  fi

  # The gateway caches tool schemas at create-gateway-target time. Delete the
  # existing target so the null_resource in modules/agentcore-gateway re-runs
  # on the next apply (which re-fetches tools/list against the new runtime
  # version).
  local target_id
  target_id=$(aws bedrock-agentcore-control list-gateway-targets \
    --region "$AWS_REGION" \
    --gateway-identifier "$gateway_id" \
    --query "items[?name=='${target_name}'].targetId | [0]" \
    --output text 2>/dev/null || echo "")
  if [[ -z "$target_id" || "$target_id" == "None" ]]; then
    _ac_log "force_mcp_runtime_image_sync: no existing '${target_name}' target on gateway ${gateway_id} — nothing to delete"
    return 0
  fi

  _ac_log "force_mcp_runtime_image_sync: deleting gateway target ${target_name} (${target_id}) so TF recreates it with refreshed tool schemas"
  aws bedrock-agentcore-control delete-gateway-target \
    --region "$AWS_REGION" \
    --gateway-identifier "$gateway_id" \
    --target-id "$target_id" \
    --output text >/dev/null 2>&1 \
    && _ac_ok "Gateway target deleted — next terraform apply will recreate with new tool schemas" \
    || _ac_warn "Gateway target delete failed — apply may not pick up new tool schemas"

  # Best-effort: also drop the null_resource from TF state so the apply re-runs
  # the local-exec instead of considering it up-to-date. Tolerates missing state
  # entries (no-op on a clean refresh).
  if [[ -n "${TF_DIR:-}" ]]; then
    (cd "$TF_DIR" && terraform state rm 'module.agentcore_gateway.null_resource.mcp_server_gateway_target[0]' >/dev/null 2>&1) \
      && _ac_log "Cleared null_resource.mcp_server_gateway_target from TF state" \
      || true
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# self_heal_failed_gateway_target <gateway_id> <target_name> <mcp_endpoint>
#
# Recovers an AgentCore Gateway target that is stuck in status=FAILED — the
# classic "target was created before the MCP runtime was warm" race that the
# Terraform null_resource only fixes when one of its triggers changes. This
# helper mirrors the null_resource's delete+recreate path but runs from the
# deploy script's post-apply smoke phase, so a single re-probe inside the same
# deploy heals the gateway instead of forcing the operator into a second
# `deploy-full-with-privatelink.sh` run.
#
# Return codes (caller chooses how to react):
#   0  Target was FAILED and was successfully deleted + recreated to READY.
#   2  Target is healthy (READY/ACTIVE) — heal is not the right rescue, the
#      probe is failing for a different reason.
#   3  Target is mid-flight (CREATING/UPDATING/DELETING) — caller should wait
#      and retry instead of triggering another delete.
#   1  Lookup/delete/recreate failed, or target never reached READY.
#
# Arguments are required; nothing is read from globals so this is safe to call
# from any phase that has loaded the relevant Terraform outputs.
#
# Related helper: `force_mcp_runtime_image_sync` (above) handles the *image
# refresh* case (new container pushed → bump runtime version → delete target
# so the next `terraform apply` recreates it). Use that helper before a TF
# apply step is available, and use this one after the last TF apply when the
# only recovery path is direct AWS CLI calls.
# ══════════════════════════════════════════════════════════════════════════════
self_heal_failed_gateway_target() {
  local gateway_id="$1"
  local target_name="$2"
  local mcp_endpoint="$3"
  local region="${AWS_REGION:-us-east-1}"

  if [[ -z "$gateway_id" || -z "$target_name" || -z "$mcp_endpoint" ]]; then
    _ac_warn "self_heal_failed_gateway_target: missing argument (gateway_id='${gateway_id}' target_name='${target_name}' endpoint set=${mcp_endpoint:+yes})"
    return 1
  fi

  local existing existing_id existing_status
  existing=$(aws bedrock-agentcore-control list-gateway-targets \
    --gateway-identifier "$gateway_id" \
    --region "$region" \
    --query "items[?name=='${target_name}'] | [0]" \
    --output json 2>/dev/null || echo null)
  if [[ -z "$existing" || "$existing" == "null" ]]; then
    _ac_warn "self_heal_failed_gateway_target: no target named '${target_name}' on gateway ${gateway_id} — nothing to heal"
    return 1
  fi
  existing_id=$(echo "$existing" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("targetId",""))' 2>/dev/null || echo "")
  existing_status=$(echo "$existing" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")

  case "$existing_status" in
    READY|ACTIVE)
      _ac_log "self-heal: target '${target_name}' (${existing_id}) is ${existing_status} — heal not applicable"
      return 2
      ;;
    CREATING|UPDATING|DELETING)
      _ac_log "self-heal: target '${target_name}' (${existing_id}) is ${existing_status} — caller should wait"
      return 3
      ;;
    FAILED)
      : # fall through to heal
      ;;
    *)
      _ac_warn "self-heal: target '${target_name}' (${existing_id}) has unexpected status '${existing_status}' — refusing to delete"
      return 1
      ;;
  esac

  local reason
  reason=$(aws bedrock-agentcore-control get-gateway-target \
    --gateway-identifier "$gateway_id" --region "$region" --target-id "$existing_id" \
    --query 'statusReasons' --output text 2>/dev/null || true)
  _ac_log "self-heal: target '${target_name}' (${existing_id}) is FAILED — deleting and recreating"
  _ac_log "self-heal:   statusReasons: ${reason}"

  if ! aws bedrock-agentcore-control delete-gateway-target \
       --gateway-identifier "$gateway_id" --region "$region" --target-id "$existing_id" \
       --output text >/dev/null 2>&1; then
    _ac_warn "self-heal: delete-gateway-target failed for ${existing_id}"
    return 1
  fi

  local _ still
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    still=$(aws bedrock-agentcore-control list-gateway-targets \
      --gateway-identifier "$gateway_id" --region "$region" \
      --query "items[?targetId=='${existing_id}'] | length(@)" \
      --output text 2>/dev/null || echo 0)
    if [[ "$still" == "0" ]]; then break; fi
    sleep 5
  done
  if [[ "$still" != "0" ]]; then
    _ac_warn "self-heal: target ${existing_id} did not disappear within 60s — aborting recreate"
    return 1
  fi

  # Pre-warm the runtime BEFORE recreating the target. The failed-target case
  # almost always coincides with a cold runtime pool, so without this step the
  # recreated target lands FAILED again with the same "Unable to connect" reason.
  # The endpoint URL-encodes the runtime ARN; decode it for invoke-agent-runtime.
  local runtime_arn
  runtime_arn=$(MCP_ENDPOINT="$mcp_endpoint" python3 -c '
import os, re, urllib.parse
endpoint = os.environ.get("MCP_ENDPOINT", "")
m = re.search(r"/runtimes/([^/]+)/invocations", endpoint)
print(urllib.parse.unquote(m.group(1)) if m else "")
' 2>/dev/null || echo "")
  if [[ -n "$runtime_arn" ]]; then
    warm_mcp_runtime "$runtime_arn"
  else
    _ac_warn "self-heal: could not extract runtime ARN from endpoint '${mcp_endpoint}' — recreate may hit cold-start race"
  fi

  _ac_log "self-heal: recreating target '${target_name}' on gateway ${gateway_id}"
  if ! aws bedrock-agentcore-control create-gateway-target \
       --region "$region" \
       --gateway-identifier "$gateway_id" \
       --name "$target_name" \
       --description "MongoDB MCP tools (AgentCore Runtime mcp-runtimes/mongodb-mcp)" \
       --target-configuration "{\"mcp\":{\"mcpServer\":{\"endpoint\":\"${mcp_endpoint}\"}}}" \
       --credential-provider-configurations \
         "[{\"credentialProviderType\":\"GATEWAY_IAM_ROLE\",\"credentialProvider\":{\"iamCredentialProvider\":{\"service\":\"bedrock-agentcore\",\"region\":\"${region}\"}}}]" \
       --output json >/dev/null 2>&1; then
    _ac_warn "self-heal: create-gateway-target failed for '${target_name}'"
    return 1
  fi

  local new_status attempt
  for attempt in $(seq 1 36); do
    new_status=$(aws bedrock-agentcore-control list-gateway-targets \
      --gateway-identifier "$gateway_id" --region "$region" \
      --query "items[?name=='${target_name}'].status | [0]" \
      --output text 2>/dev/null || echo "")
    case "$new_status" in
      READY|ACTIVE)
        _ac_ok "self-heal: target '${target_name}' is ${new_status} after ${attempt} poll(s) — gateway healed"
        return 0
        ;;
      FAILED)
        local new_id new_reason
        new_id=$(aws bedrock-agentcore-control list-gateway-targets \
          --gateway-identifier "$gateway_id" --region "$region" \
          --query "items[?name=='${target_name}'].targetId | [0]" \
          --output text 2>/dev/null || echo "")
        new_reason=$(aws bedrock-agentcore-control get-gateway-target \
          --gateway-identifier "$gateway_id" --region "$region" --target-id "$new_id" \
          --query 'statusReasons' --output text 2>/dev/null || true)
        _ac_warn "self-heal: recreated target ${new_id} is also FAILED — root cause is NOT a stale gateway"
        _ac_warn "self-heal:   statusReasons: ${new_reason}"
        return 1
        ;;
    esac
    sleep 5
  done
  _ac_warn "self-heal: target '${target_name}' did not reach READY within 180s (last status: ${new_status:-?})"
  return 1
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
          "${AGENTCORE_GATEWAY_URL:-}" "${SPECIALIST_IDS_JSON:-[]}"
import json, sys
env            = json.loads(sys.argv[1] or "{}")
label          = sys.argv[2]
expected_agent = sys.argv[3]
is_orch        = sys.argv[4] == "yes"
expected_gw    = sys.argv[5]
specialist_ids = json.loads(sys.argv[6])

def fail(msg):
    raise SystemExit(f"{label}: {msg}")

if env.get("AGENT_ID") != expected_agent:
    fail(f"AGENT_ID expected '{expected_agent}', got '{env.get('AGENT_ID')}'")
# MCP Gateway env var: required on every runtime regardless of caller shell
# state. Mongo tool traffic must go through AgentCore Gateway; the dedicated
# MongoDB MCP runtime ARN/endpoint is infrastructure wiring for the Gateway
# target and is intentionally not injected into application runtimes.
if not env.get("AGENTCORE_GATEWAY_URL"):
    fail("AGENTCORE_GATEWAY_URL missing on runtime (post-Phase 6b)")
if expected_gw and env.get("AGENTCORE_GATEWAY_URL") != expected_gw:
    fail(f"AGENTCORE_GATEWAY_URL mismatch (got '{env.get('AGENTCORE_GATEWAY_URL')}', want '{expected_gw}')")
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
