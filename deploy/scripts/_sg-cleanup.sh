# Shared helpers for deleting stale security-group references before Terraform
# tries to delete the referenced group.

cleanup_security_group_references() {
  if [[ $# -eq 0 ]]; then
    return 0
  fi

  local _target_sgs=("$@")
  python3 - "$AWS_REGION" "${_target_sgs[@]}" <<'PYEOF'
import json
import subprocess
import sys

region = sys.argv[1]
targets = [sg for sg in sys.argv[2:] if sg and sg != "None"]


def aws(args):
    return subprocess.run(
        ["aws", "--region", region, *args],
        check=False,
        capture_output=True,
        text=True,
    )


def revoke_reference(target_sg):
    described = aws([
        "ec2",
        "describe-security-groups",
        "--filters",
        f"Name=ip-permission.group-id,Values={target_sg}",
        "--output",
        "json",
    ])
    if described.returncode != 0:
        print(described.stderr.strip(), file=sys.stderr)
        return 0

    revoked = 0
    for group in json.loads(described.stdout or "{}").get("SecurityGroups", []):
        group_id = group.get("GroupId")
        for permission in group.get("IpPermissions", []):
            matching_pairs = [
                {"GroupId": pair["GroupId"]}
                for pair in permission.get("UserIdGroupPairs", [])
                if pair.get("GroupId") == target_sg
            ]
            if not matching_pairs:
                continue

            revoke_permission = {
                "IpProtocol": permission["IpProtocol"],
                "UserIdGroupPairs": matching_pairs,
            }
            if "FromPort" in permission:
                revoke_permission["FromPort"] = permission["FromPort"]
            if "ToPort" in permission:
                revoke_permission["ToPort"] = permission["ToPort"]

            result = aws([
                "ec2",
                "revoke-security-group-ingress",
                "--group-id",
                group_id,
                "--ip-permissions",
                json.dumps([revoke_permission]),
            ])
            if result.returncode == 0:
                print(f"revoked ingress reference: {group_id} -> {target_sg}")
                revoked += 1
            elif "InvalidPermission.NotFound" in result.stderr:
                continue
            else:
                print(result.stderr.strip(), file=sys.stderr)
    return revoked


total = 0
for target in targets:
    total += revoke_reference(target)

if total:
    print(f"revoked {total} stale security-group reference(s)")
PYEOF
}

cleanup_project_security_group_references() {
  local _target_sgs
  _target_sgs=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters \
      "Name=group-name,Values=${PROJECT_NAME}-sg-ec2-${ENVIRONMENT},${PROJECT_NAME}-sg-mcp-runtime-${ENVIRONMENT}" \
    --query 'SecurityGroups[].GroupId' \
    --output text 2>/dev/null || true)

  if [[ -z "$_target_sgs" || "$_target_sgs" == "None" ]]; then
    return 0
  fi

  cleanup_security_group_references $_target_sgs
}
