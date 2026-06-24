#!/usr/bin/env bash
# _seed-embeddings.sh — shared helper for running db-seeding/seed-embeddings.ts.
#
# Sourceable bash module. Provides:
#   run_embedding_seed <db_name> <mongo_uri>
#
# Responsibilities (centralised so every caller gets the same hardened path):
#   1. Provider env mapping: read EMBEDDINGS_PROVIDER (`voyage` / `titan`) and
#      export the script-native env vars the TS script reads
#      (VOYAGE_SAGEMAKER_ENDPOINT / EMBEDDING_MODEL_ID).
#   2. Multi-signal REWIRE auto-detect (dim comes from voyage_embedding_dims():
#        a. SSM dim parameter `/${SHARED_VPC_NAME}/${region}/embeddings/dim`
#           ≠ current resolved embedding dim (voyage_embedding_dims).
#        b. In-Mongo dimension fingerprint: sample one seeder-owned doc and
#           check embedding.length vs current resolved embedding dim.
#        c. In-Mongo provider fingerprint: sample one seeder-owned doc and
#           check embeddingModel substring vs current EMBEDDINGS_PROVIDER.
#   3. SageMaker InService polling wait (when EMBEDDINGS_PROVIDER=voyage).
#   4. Mongo connectivity pre-check via _mongo-connect.sh.
#   5. Invoke `bun db-seeding/seed-embeddings.ts` and propagate non-zero exit.
#   6. Post-success SSM write-back of the dim parameter.
#   7. EMF metric on failure (Multiagent/Memory EmbeddingSeedFailure=1).
#
# Idempotent sourcing.

if [[ -n "${_SEED_EMBEDDINGS_SH_SOURCED:-}" ]]; then
  return 0
fi

# Voyage SSOT bridge — provides voyage_embedding_dims() so we never hand-roll
# the dim literal in this file (catches drift if the TS SSOT changes).
_SE_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/scripts/_voyage-config.sh
source "$_SE_HELPER_DIR/_voyage-config.sh"

_SEED_EMBEDDINGS_SH_SOURCED=1

# Ensure connect helper is available (idempotent if already sourced).
_SE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/scripts/_mongo-connect.sh
source "$_SE_SCRIPT_DIR/_mongo-connect.sh"

_se_log()  { echo "  [embed-seed] $*"; }
_se_warn() { echo "  [embed-seed] ⚠ $*"; }
_se_err()  { echo "  [embed-seed] ✗ $*" >&2; }

# wait_voyage_endpoint_inservice <endpoint_name>
# Polls EndpointStatus every 30s. Aborts on timeout.
# SIGPIPE-safe: captures aws output into a variable, no head/grep/awk pipes
# inside $().
wait_voyage_endpoint_inservice() {
  local endpoint="$1"
  local region="${AWS_REGION:-us-east-1}"
  local timeout=900
  if [[ -z "$endpoint" ]]; then
    _se_err "wait_voyage_endpoint_inservice: endpoint name is empty"
    return 1
  fi
  local started=$SECONDS
  local status="" err=""
  while (( SECONDS - started < timeout )); do
    status="$(aws sagemaker describe-endpoint \
      --endpoint-name "$endpoint" \
      --region "$region" \
      --query 'EndpointStatus' --output text 2>/tmp/_voyage_endpoint_wait_err.txt || true)"
    err="$(cat /tmp/_voyage_endpoint_wait_err.txt 2>/dev/null || true)"
    case "$status" in
      InService) _se_log "Voyage endpoint InService: ${endpoint}"; return 0 ;;
      Creating|Updating|SystemUpdating) _se_log "Voyage endpoint ${endpoint} is '${status}' — waiting…" ;;
      Failed|OutOfService|Deleting|RollingBack)
        _se_err "Voyage endpoint ${endpoint} is '${status}' (terminal). aws error: ${err:-none}"
        return 1
        ;;
      *) _se_warn "Voyage endpoint ${endpoint} status='${status:-?}' (aws err: ${err:-none})" ;;
    esac
    sleep 30
  done
  _se_err "Timed out after ${timeout}s waiting for Voyage endpoint InService (last status: ${status:-?})"
  return 1
}

# _se_emit_failure_metric — best-effort EMF/PutMetricData call so operators
# can wire CloudWatch alarms on embedding seed failures. Never fails the script.
_se_emit_failure_metric() {
  local region="${AWS_REGION:-us-east-1}"
  aws cloudwatch put-metric-data \
    --region "$region" \
    --namespace Multiagent/Memory \
    --metric-name EmbeddingSeedFailure \
    --value 1 \
    --unit Count \
    --dimensions Environment="${ENVIRONMENT:-dev}",Project="${PROJECT_NAME:-multiagent}" \
    >/dev/null 2>&1 || true
}

# Returns "yes" if a REWIRE is needed based on any signal, "no" otherwise.
# Writes diagnostic to stderr so operator sees which signal tripped.
_se_should_rewire() {
  local mongo_uri="$1"
  local db_name="$2"
  local current_dim
  current_dim="$(voyage_embedding_dims)"
  local provider="${EMBEDDINGS_PROVIDER:-titan}"
  local region="${AWS_REGION:-us-east-1}"
  local svn="${SHARED_VPC_NAME:-shared-network}"

  # Signal 1: SSM dim ≠ current.
  local stored_dim
  stored_dim="$(aws ssm get-parameter --region "$region" --name "/${svn}/${region}/embeddings/dim" --query 'Parameter.Value' --output text 2>/dev/null || echo "")"
  if [[ -n "$stored_dim" && "$stored_dim" != "None" && "$stored_dim" != "$current_dim" ]]; then
    _se_warn "REWIRE signal: SSM dim=${stored_dim} ≠ current resolved embedding dim=${current_dim}" >&2
    echo "yes"
    return 0
  fi

  # Signal 2 + 3: in-Mongo fingerprint. Bun probe of products.findOne.
  if ! command -v bun >/dev/null 2>&1; then
    echo "no"
    return 0
  fi
  local probe_out
  probe_out="$(MONGO_URI="$mongo_uri" MONGO_DB="$db_name" CURRENT_DIM="$current_dim" CURRENT_PROVIDER="$provider" bun -e '
const { MongoClient } = await import(process.env.MONGO_PROBE_DRIVER_SPEC || "mongodb"); // spec from _transient-errors.sh; bare import floats to bson@7.3.0 which crashes under Bun 1.3.13 (see mongo-probe-bun-bson-failure-report.md)
const uri = process.env.MONGO_URI;
const dbName = process.env.MONGO_DB;
const expectedDim = Number(process.env.CURRENT_DIM || "1024");
const provider = process.env.CURRENT_PROVIDER || "titan";
const client = new MongoClient(uri, { appName: "rewire-detect", serverSelectionTimeoutMS: 8000 });
try {
  await client.connect();
  for (const name of ["products", "troubleshooting_docs"]) {
    const filter = name === "troubleshooting_docs"
      ? { bedrock_text_chunk: { $exists: false }, embedding: { $exists: true, $type: "array" } }
      : { embedding: { $exists: true, $type: "array" } };
    const sample = await client.db(dbName).collection(name).findOne(filter, { projection: { embedding: 1, embeddingModel: 1 } });
    if (!sample) continue;
    if (Array.isArray(sample.embedding) && sample.embedding.length !== expectedDim) {
      process.stdout.write(`DIM ${name} got=${sample.embedding.length} want=${expectedDim}`);
      process.exit(0);
    }
    const model = (sample.embeddingModel || "").toLowerCase();
    if (model) {
      const wantSubstring = provider === "voyage" ? "voyage:" : "bedrock:";
      if (!model.startsWith(wantSubstring)) {
        process.stdout.write(`PROV ${name} model=${model} want=${wantSubstring}*`);
        process.exit(0);
      }
    }
  }
  process.stdout.write("OK");
} catch (e) {
  process.stdout.write("ERR " + (e && e.message ? e.message : String(e)));
} finally {
  try { await client.close(); } catch (_) {}
}
' 2>/dev/null || true)"
  if [[ "$probe_out" == DIM* || "$probe_out" == PROV* ]]; then
    _se_warn "REWIRE signal: in-Mongo fingerprint differs (${probe_out})" >&2
    echo "yes"
    return 0
  fi
  echo "no"
}

# run_embedding_seed <db_name> <mongo_uri>
#
# Returns 0 on success, non-zero on failure (caller is expected to fail
# the deploy on non-zero — the warn-only fallback is intentionally removed).
run_embedding_seed() {
  local db_name="$1"
  local mongo_uri="$2"

  if [[ -z "$db_name" ]]; then
    _se_err "run_embedding_seed: db_name is empty"
    return 1
  fi
  if [[ -z "$mongo_uri" ]]; then
    _se_err "run_embedding_seed: mongo_uri is empty"
    return 1
  fi

  local provider="${EMBEDDINGS_PROVIDER:-}"
  if [[ -z "$provider" ]]; then
    _se_err "EMBEDDINGS_PROVIDER not set — deploy must explicitly select voyage|titan"
    return 1
  fi

  # Provider env mapping (script-native env vars seed-embeddings.ts reads).
  case "$provider" in
    voyage)
      if [[ -z "${VOYAGE_SAGEMAKER_ENDPOINT:-${VOYAGE_ENDPOINT:-}}" ]]; then
        _se_err "EMBEDDINGS_PROVIDER=voyage but VOYAGE_SAGEMAKER_ENDPOINT/VOYAGE_ENDPOINT not set"
        return 1
      fi
      export VOYAGE_SAGEMAKER_ENDPOINT="${VOYAGE_SAGEMAKER_ENDPOINT:-${VOYAGE_ENDPOINT:-}}"
      # Belt-and-suspenders: unset Bedrock model id so seed-embeddings.ts
      # routes exclusively through Voyage.
      unset EMBEDDING_MODEL_ID
      _se_log "Waiting for Voyage SageMaker endpoint InService: ${VOYAGE_SAGEMAKER_ENDPOINT}"
      wait_voyage_endpoint_inservice "$VOYAGE_SAGEMAKER_ENDPOINT" || {
        _se_emit_failure_metric
        return 1
      }
      ;;
    titan)
      export EMBEDDING_MODEL_ID="${EMBEDDING_MODEL_ID:-amazon.titan-embed-text-v2:0}"
      unset VOYAGE_SAGEMAKER_ENDPOINT
      ;;
    *)
      _se_err "EMBEDDINGS_PROVIDER='${provider}' is unsupported (must be voyage|titan)"
      return 1
      ;;
  esac

  # Pre-seed Mongo reachability — fail fast with sanitized URI envelope
  # rather than letting the bun script timeout deep inside the seeder.
  if ! assert_mongo_reachable "$mongo_uri" "$db_name" 300; then
    _se_emit_failure_metric
    return 1
  fi

  # Decide REWIRE.
  local rewire="no"
  rewire="$(_se_should_rewire "$mongo_uri" "$db_name")"
  if [[ "$rewire" == "yes" ]]; then
    _se_log "Auto-enabling REWIRE_EMBEDDINGS=1 (provider/dim change detected)"
    export REWIRE_EMBEDDINGS=1
  else
    # Explicit override still honored.
    if [[ -n "${REWIRE_EMBEDDINGS:-}" && "${REWIRE_EMBEDDINGS}" == "1" ]]; then
      _se_log "REWIRE_EMBEDDINGS=1 set explicitly by operator"
    else
      unset REWIRE_EMBEDDINGS || true
    fi
  fi

  local repo_root="${REPO_ROOT:-$(cd "$_SE_SCRIPT_DIR/../.." && pwd)}"

  # Install db-seeding deps from the lockfile before running the seeder.
  # Without this step, Bun auto-installs from the global cache and can
  # silently resolve a newer @smithy/core (e.g. 3.24.x) that pulled in by
  # api/ packages — even though db-seeding/bun.lock pins 3.23.x. That newer
  # version uses @smithy/core/schema subpath exports which Bun <=1.3.x
  # cannot resolve, causing "Cannot find module '@smithy/core/schema'".
  _se_log "Installing db-seeding dependencies (--frozen-lockfile)"
  ( cd "$repo_root/db-seeding" && bun install --frozen-lockfile 2>&1 | sed 's/^/  [embed-seed] /' ) || {
    _se_err "bun install failed in db-seeding/ — cannot seed embeddings"
    _se_emit_failure_metric
    return 1
  }

  # Bun's AWS SDK http2 handler drops Bedrock responses on macOS (Smithy
  # "http2 request did not get a response"); Node is reliable for Titan seeding.
  local seed_runner="bun"
  local seed_invocation="db-seeding/seed-embeddings.ts"
  if [[ "$provider" == "titan" ]]; then
    command -v node >/dev/null 2>&1 \
      || { _se_err "EMBEDDINGS_PROVIDER=titan requires node on PATH for seed-embeddings.ts (Bun http2 + Bedrock is broken)"; return 1; }
    seed_runner="node"
    seed_invocation="--experimental-strip-types db-seeding/seed-embeddings.ts"
  fi
  _se_log "Running ${seed_runner} ${seed_invocation} (provider=${provider})"
  local seed_rc=0
  (
    cd "$repo_root"
    MONGODB_URI="$mongo_uri" \
    MONGODB_DB="$db_name" \
    AWS_REGION="${AWS_REGION:-us-east-1}" \
    EMBEDDINGS_PROVIDER="$provider" \
    ${seed_runner} ${seed_invocation}
  ) || seed_rc=$?
  if (( seed_rc != 0 )); then
    _se_err "seed-embeddings.ts exited non-zero (rc=${seed_rc})"
    _se_emit_failure_metric
    return "$seed_rc"
  fi

  # Post-success: write the SSM dim so future deploys can compare authoritatively.
  local region="${AWS_REGION:-us-east-1}"
  local svn="${SHARED_VPC_NAME:-shared-network}"
  local cur_dim
  cur_dim="$(voyage_embedding_dims)"
  aws ssm put-parameter --region "$region" \
    --name "/${svn}/${region}/embeddings/dim" \
    --value "$cur_dim" \
    --type String \
    --overwrite >/dev/null 2>&1 \
    && _se_log "SSM dim parameter written: /${svn}/${region}/embeddings/dim=${cur_dim}" \
    || _se_warn "Could not write SSM dim parameter (non-fatal)"

  _se_log "✓ embedding seed complete (provider=${provider}, dim=${cur_dim})"
  return 0
}
