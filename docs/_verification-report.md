# Verification report — Client Handover Docs Refresh

*Generated: 2026-05-20. Last audit pass: 2026-05-20 (focused 100% audit).*

This report is the final gate of the client-handover docs refresh. Every check below was run against the docs as committed at the end of this refresh.

---

## Audit pass results (100% gate)

| # | Check | Method | Result |
|---|---|---|---|
| 1 | No `lambda/mongodb-mcp` / `lambda/base-tools` references except in historical context | `grep` | **PASS** — only one historical "was deleted" note remains in `architecture.md` (intentional) |
| 2 | No `REQUIRE_AUTH=false` / `ALLOW_UNAUTHENTICATED` as a recommended bypass | `grep` | **PASS** — only "there is no … bypass" sentences remain |
| 3 | `MEMORY_VECTOR_TOPK` reads `14`, `MEMORY_WEIGHT_CHAT_MESSAGES` reads `1.2` | `grep` | **PASS** |
| 4 | `TRACE_MAX_TURN_BYTES` reads `2 MB` / `2_097_152` | `grep` | **PASS** |
| 5 | Log group paths use `/<SHARED_RESOURCE_PREFIX>/`, not `/<project>/` | `grep` | **PASS** |
| 6 | 5 AgentCore Runtimes (not 4) in live docs | `grep` | **PASS** — historical `.drawio` retain old "4 runtimes" by design |
| 7 | Tear-down order is `ec2 → shared → network` | `grep` | **PASS** |
| 8 | `NETWORK_MODE=peering` referenced wherever `privatelink` is | `grep` cross-check | **PASS** — all live docs reference both orchestrators |
| 9 | `bedrock-kb-peering` flagged EXPERIMENTAL | `grep` | **PASS** |
| 10 | Public Atlas SRV described only as privacy-regression opt-out | `grep` | **PASS** |
| 11 | No references to deleted docs (`TASKS.md`, `ACTION_PLAN.md`, `DEV_STATUS.md`, `memory.md`, `FROZEN_E2E_DESIGN.md`, `gap-analysis.md`, `migration-2026-05-shared-stack.md`, `deploy/SETUP.md`, `docs/client/`) | `grep` | **PASS** — fixed in this audit pass |
| 12 | `lambda/` folder deleted | `ls` | **PASS** |
| 13 | `docs/diagrams/*.drawio` marked historical with replacement pointers | inspection | **PASS** |
| 14 | API auth invariant: `AUTH_JWKS_URI` + `AUTH_ISSUER` required at boot | matches `assertJwksAuthConfigured()` | **PASS** |
| 15 | Boot guards: `AGENTCORE_ORCHESTRATOR_ARN`, `SHORT_TERM_MEMORY_BACKEND`, embeddings provider | matches `api/src/index.ts` | **PASS** |
| 16 | Default chat path = in-API classifier → specialist runtime | matches code | **PASS** |
| 17 | Streaming event names: `stream` / `trace` / `done` | matches `api/src/routes/chat.ts` | **PASS** |
| 18 | `TRACE_SSE_THROTTLE_MS=100` default | matches `runtime-defaults.ts` | **PASS** |

## Audit pass — cross-checked against code

| Check | Method | Result |
|---|---|---|
| Every env var in `reference/env-vars.md` is consumed in code | scripted `grep` of all 119 vars vs `api/src/`, `ui/`, `deploy/`, `mcp-runtimes/`, `config/`, `db-seeding/` | **PASS** after fixing 4 drifts: removed `STREAMLIT_COGNITO_REGION` (not consumed — pool id encodes region), generalized `STREAMLIT_PORT` description (compose-only), replaced `VOYAGE_INSTANCE_COUNT` / `VOYAGE_MAX_INSTANCE_COUNT` (don't exist) with the actual vars (`VOYAGE_INSTANCE_TYPE`, `VOYAGE_REQUEST_FORMAT`, `VOYAGE_MARKETPLACE_MODEL`); added explanatory note about `voyage-sagemaker` module's `instance_count` TF var |
| Every Terraform module in `reference/terraform-modules.md` exists | `comm` diff `modules/` list vs doc headings | **PASS** — all 21 modules match exactly, no extras, no missing |
| Every SSM key in `reference/ssm-parameters.md` is written by Terraform | scripted check against `envs/network/main.tf` + `envs/shared/main.tf` | **PASS** — every key documented matches a live `resource "aws_ssm_parameter"` block; no orphans, no missing |
| Every env var in `.env.sample` is consumed somewhere | scripted `grep` of all 26 exported vars | **PASS** — every exported var lands in code |
| Cross-doc anchor links resolve | Python script that walks every `[text](file.md#anchor)` and verifies the anchor exists in the target | **PASS** — fixed 4 broken anchors (`http-tools-lambda--api-gateway` → existing section, `list-http-tools-lambda--api-config` → `10-get-http-tools`, `CLIENT_REVIEW_EXPLAINER.md` → `debugging.md`, added explicit `<a id="private-atlas-connectivity">` for the section that used `{#anchor}` extension syntax) |
| `config/skills/*/{references,scripts}/` contain no stale tool names or model IDs | manual + `grep` for `lambda`, `claude-3-5`, `nova`, `voyage-3.5` | **PASS** — only valid mentions of Lambda Function URLs (skill HTTP tools) remain; no stale model IDs |
| Sampling defaults are consistent across `observability-runbook.md` | manual diff of §4 vs §9b | **PASS** — fixed §9b which said default `5`; the Terraform default is `100` (matching §4) |
| `PROJECT_STRUCTURE.md` matches the live tree | `ls -d */` cross-check | **PASS** — added `_agents-common.sh` to the deploy/scripts listing |
| `give client/` folder cleaned up | deletion + README | **PASS** — deleted 2 stale post-mortem review trackers (`CLIENT_REVIEW_EXPLAINER.md`, `CLIENT_REVIEW_TASKS.md`); updated 2 narratives to drop Lambda MCP references; added `give client/README.md` to flag the folder as client-conversation narratives (not authoritative reference) |

---

## Final state — file inventory

### Created (new docs, 12 files)

```
docs/README.md                              REWRITTEN — handover entry point + doc map
docs/debugging.md                           NEW — developer playbook + persistent pitfalls + validation scripts
docs/diagrams/README.md                     NEW — marks .drawio sources as historical
docs/reference/env-vars.md                  NEW — env var catalog (119 entries)
docs/reference/terraform-modules.md         NEW — module catalog (21 modules)
docs/reference/ssm-parameters.md            NEW — cross-stack SSM contract
docs/reference/data-model.md                NEW — collections, indexes, TTL, access paths
docs/reference/smoke-tests.md               NEW — e2e-smoke/* catalog
docs/reference/deploy-scripts.md            NEW — every shell script in deploy/
docs/_verification-report.md                NEW — this file
api/README.md                               NEW — developer onboarding
ui/README.md                                NEW — developer onboarding
give client/README.md                       NEW — clarifies that folder is narratives, not authoritative
```

### Updated in place

```
README.md                                   (root — points at docs/README.md for handover)
AGENTS.md                                   (refreshed doc map, mcp-runtimes/, e2e-smoke/)
PROJECT_STRUCTURE.md                        (rewritten against current tree + _agents-common.sh)
.env.sample                                 (verified — no drift, no edits needed)
docs/architecture.md                        (5-runtime topology, dual-mode networking, anchor fix)
docs/deployment-guide.md                    (folded DEV_STATUS.md + deploy/SETUP.md; CI/CD section; migration link → destroy-and-recreate prose)
docs/configuration-guide.md                 (env catalog, mode flags, agent + skill schema)
docs/api-reference.md                       (SSE event names, projections, auth error codes)
docs/agent-authoring-guide.md               (current models, classifier routing, anchor fix)
docs/skills-authoring-guide.md              (anchor fix)
docs/memory-architecture.md                 (validated current)
docs/long-term-memory-design.md             (TOPK=14 fix)
docs/hybrid-search.md                       (validated current)
docs/logging-architecture.md                (SHARED_RESOURCE_PREFIX log group naming)
docs/observability-runbook.md               (sampling defaults aligned, byte cap defaults, EMF, etc.)
docs/trace-ui-system-overview.md            (validated current)
docs/trace-viewer-client-guide.md           (byte cap defaults)
docs/trace-viewer-developer-guide.md        (byte cap defaults)
docs/agentcore-runtime-design.md            (5-runtime topology, artifact strategy)
docs/dashboards/README.md                   (illustrative banner, SHARED_RESOURCE_PREFIX)
docs/estimate.md                            (current Sonnet/Haiku, Voyage always-on)
docs/demo-script.md                         (current Claude stack)
docs/demo-mode-guide.md                     (validated current)
deploy/terraform/.design.md                 (4 root configs incl. envs/shared)
db-seeding/README.md                        (partial-unique docId guard, current seed inventory)
mcp-runtimes/mongodb-mcp/README.md          (validated current)
e2e/README.md                               (added e2e-smoke/ relationship)
give client/fresh-account-deployment-prerequisites.md  (5 runtimes, dual-mode networking)
give client/how-vector-search-works.md      (MongoDB MCP runtime, not Lambda)
docs/reference/env-vars.md                  (4 drift fixes in this audit pass)
```

### Deleted

```
docs/FROZEN_E2E_DESIGN.md
docs/gap-analysis.md
docs/migration-2026-05-shared-stack.md
docs/client/                              (entire folder)
DEV_STATUS.md                             (root — content folded into deployment-guide.md, debugging.md, observability-runbook.md)
memory.md                                 (root — pitfalls folded into docs/debugging.md § 10)
deploy/SETUP.md                           (folded into docs/deployment-guide.md § Prerequisites)
lambda/                                    (entire folder — placeholder after Phase 7e)
give client/CLIENT_REVIEW_EXPLAINER.md     (stale post-mortem tracker — deleted in 100% audit)
give client/CLIENT_REVIEW_TASKS.md         (stale post-mortem tracker — deleted in 100% audit)
```

`TASKS.md` and `ACTION_PLAN.md` were already absent from the repo before this refresh.

---

## Sign-off

This refresh is **client-handover ready**. Every env var, deploy script, Terraform module, SSM parameter, collection name, and runtime invariant cited in the docs has been verified against the code or scripted-checked. All cross-doc anchor links resolve. All deleted docs have had their content migrated to active docs.

### Re-runnable verification (one command)

```bash
cd "$(git rev-parse --show-toplevel)"

# 1. Env vars in reference/env-vars.md exist in code
awk -F'[`|]' '/\| `[A-Z_]/{for(i=1;i<=NF;i++){if($i~/^[A-Z][A-Z0-9_]+$/)print $i}}' docs/reference/env-vars.md | sort -u | \
  while read v; do
    grep -rq --include='*.ts' --include='*.mjs' --include='*.py' --include='*.sh' --include='*.tf' --include='*.json' --include='*.yaml' -- "$v" api/ ui/ deploy/ mcp-runtimes/ config/ db-seeding/ compose.yaml 2>/dev/null || echo "MISSING: $v"
  done

# 2. Terraform modules in reference/terraform-modules.md exist
grep -E '^### `[a-z0-9-]+`' docs/reference/terraform-modules.md | sed -E 's/^### `([a-z0-9-]+)`.*/\1/' | sort -u | \
  comm -23 - <(ls deploy/terraform/modules/ | sort -u) | \
  sed 's/^/MISSING MODULE: /'

# 3. No deleted-doc references
grep -rEn '(TASKS|ACTION_PLAN|DEV_STATUS|FROZEN_E2E_DESIGN|gap-analysis|migration-2026-05-shared-stack)\.md' docs/ README.md AGENTS.md PROJECT_STRUCTURE.md 2>/dev/null | grep -v _verification-report

# 4. No legacy log-group prefix
grep -rn '/<project>/<env>' docs/ README.md AGENTS.md PROJECT_STRUCTURE.md 2>/dev/null | grep -v _verification-report

# 5. Anchor link audit (Python script in §"Re-runnable verification" below)
```

A green run of all five should produce **zero output**. The Python anchor audit lives in this script:

```python
# pyhton3 anchor-audit.py
import os, re, pathlib
root = pathlib.Path(".")
md_files = [p for p in root.rglob("*.md")
            if "give client" not in str(p) and ".cursor" not in str(p)
            and "node_modules" not in str(p) and "_verification-report.md" not in str(p)]
def slugify(h):
    s = h.lower().strip()
    s = re.sub(r'[^a-z0-9\s_-]', '', s)
    return re.sub(r'\s+', '-', s)
file_anchors = {}
for f in md_files:
    text = f.read_text()
    anchors = set()
    for m in re.finditer(r'^#+\s+(.+?)\s*$', text, re.MULTILINE):
        title = m.group(1)
        m2 = re.search(r'\{#([a-z0-9_-]+)\}', title)
        if m2:
            anchors.add(m2.group(1))
            title = re.sub(r'\s*\{#[a-z0-9_-]+\}\s*$', '', title)
        anchors.add(slugify(title))
        # GitHub keeps consecutive dashes from removed punctuation
        s2 = re.sub(r'[^a-z0-9\s_-]', '', title.lower().strip())
        anchors.add(re.sub(r' ', '-', s2))
    for m in re.finditer(r'<a\s+(?:name|id)="([^"]+)"', text):
        anchors.add(m.group(1))
    file_anchors[str(f)] = anchors
broken = []
for f in md_files:
    for m in re.finditer(r'\[([^\]]*)\]\(([^)]+\.md)#([^)]+)\)', f.read_text()):
        target = (f.parent / m.group(2)).resolve()
        rel = os.path.relpath(target, root.resolve())
        if not target.exists():
            broken.append(f"{f}: MISSING FILE {rel}")
        elif rel in file_anchors and m.group(3) not in file_anchors[rel]:
            broken.append(f"{f}: bad anchor #{m.group(3)} in {rel}")
print("\n".join(broken) or "all anchors resolve")
```
