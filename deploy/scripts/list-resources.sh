#!/usr/bin/env bash
# list-resources.sh — list every AWS resource tagged with our Project tag.
#
# Usage:
#   ./deploy/scripts/list-resources.sh              # defaults to multiagent-mongodb-framework
#   ./deploy/scripts/list-resources.sh my-project   # override
#   PROJECT_NAME=my-project ./deploy/scripts/list-resources.sh
#   ./deploy/scripts/list-resources.sh --region us-east-2
#
# What it does:
#   1. Uses resourcegroupstaggingapi to get every tagged resource in the region.
#   2. Groups and counts them by service for a quick "did my deploy create what I expected" view.
#   3. Also lists Bedrock AgentCore Memory + Gateway (they don't show up in
#      resourcegroupstaggingapi yet — we ask the agentcore-control API directly).
#   4. Flags a prompt at the end you can pipe into untag-resources / delete commands.
#
# Intended for iterative policy-testing: run after each `deploy.sh` to see
# exactly which resources the IAM policy was powerful enough to create.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-multiagent-mongodb-framework}"
AWS_REGION="${AWS_REGION:-us-east-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift ;;
    --project) PROJECT_NAME="$2"; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) PROJECT_NAME="$1" ;;
  esac
  shift
done

sep() { echo "──────────────────────────────────────────────────────────────────"; }

sep
echo "  Project tag : $PROJECT_NAME"
echo "  AWS region  : $AWS_REGION"
sep

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }
aws sts get-caller-identity --query Account --output text >/dev/null 2>&1 \
  || { echo "AWS credentials invalid — source env.sh first" >&2; exit 1; }

# ── 1. Everything the Resource Groups Tagging API knows about ───────────────
echo "  Tagged AWS resources (via resourcegroupstaggingapi):"
RESOURCES_JSON=$(aws resourcegroupstaggingapi get-resources \
  --region "$AWS_REGION" \
  --tag-filters "Key=Project,Values=${PROJECT_NAME}" \
  --output json 2>/dev/null || echo '{"ResourceTagMappingList":[]}')

TOTAL=$(echo "$RESOURCES_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['ResourceTagMappingList']))")
echo "  Total tagged resources: $TOTAL"
echo ""

if [[ "$TOTAL" -gt 0 ]]; then
  echo "$RESOURCES_JSON" | python3 -c "
import json, sys, collections
d = json.load(sys.stdin)
buckets = collections.defaultdict(list)
for r in d['ResourceTagMappingList']:
    arn = r['ResourceARN']
    parts = arn.split(':')
    svc = parts[2] if len(parts) > 2 else '?'
    buckets[svc].append(arn)
for svc in sorted(buckets):
    print(f'  [{svc}]  ({len(buckets[svc])})')
    for arn in sorted(buckets[svc]):
        print(f'    {arn}')
"
fi

# ── 2. Bedrock AgentCore (not in resourcegroupstaggingapi yet) ──────────────
echo ""
sep
echo "  Bedrock AgentCore resources (direct API):"
MEMS=$(aws bedrock-agentcore-control list-memories \
  --region "$AWS_REGION" \
  --query "memories[?starts_with(name, \`${PROJECT_NAME//-/_}\`) || starts_with(name, \`${PROJECT_NAME}\`)].{name:name,id:id,arn:arn}" \
  --output json 2>/dev/null || echo '[]')
MEM_COUNT=$(echo "$MEMS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
echo "  Memory stores: $MEM_COUNT"
[[ "$MEM_COUNT" -gt 0 ]] && echo "$MEMS" | python3 -c "
import json, sys
for m in json.load(sys.stdin):
    print(f'    {m[\"name\"]}  ({m[\"id\"]})')
"

GWS=$(aws bedrock-agentcore-control list-gateways \
  --region "$AWS_REGION" \
  --query "items[?starts_with(name, \`${PROJECT_NAME//-/_}\`) || starts_with(name, \`${PROJECT_NAME}\`)].{name:name,id:gatewayId,arn:gatewayArn,url:gatewayUrl}" \
  --output json 2>/dev/null || echo '[]')
GW_COUNT=$(echo "$GWS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
echo "  Gateways: $GW_COUNT"
[[ "$GW_COUNT" -gt 0 ]] && echo "$GWS" | python3 -c "
import json, sys
for g in json.load(sys.stdin):
    print(f'    {g[\"name\"]}  ({g[\"id\"]})  url={g.get(\"url\",\"\")}')
"

sep
echo ""
echo "  To delete EVERYTHING with this tag:"
echo "    ./deploy/scripts/destroy.sh --mode ec2   # or --mode local"
echo ""
echo "  To filter AWS Cost Explorer by this tag:"
echo "    Billing → Cost Explorer → Filter → Tag: Project = ${PROJECT_NAME}"
echo "    (First enable in Billing → Cost Allocation Tags → activate 'Project'.)"
echo ""
