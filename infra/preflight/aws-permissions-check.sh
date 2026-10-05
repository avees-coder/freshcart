#!/usr/bin/env bash
# ZG527 account preflight, part 1 — run in AWS CloudShell (ap-south-1). Launches NOTHING.
# Uses --dry-run: AWS evaluates IAM policies and organisation SCPs, then stops.
#   DryRunOperation      = you WOULD be allowed
#   UnauthorizedOperation = blocked (by IAM or an SCP)
# Usage:  SG_ID=sg-xxxxxxxx bash infra/preflight/aws-permissions-check.sh
#         (SG_ID optional: an existing security group to test rule edits on)
set -uo pipefail
REGION="${REGION:-ap-south-1}"
SG_ID="${SG_ID:-}"
NEED_VCPU=12          # 5 x t3.small (2 vCPU) + 1 x t3.medium (2 vCPU)
FAILS=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAILS=$((FAILS+1)); }
dry() {   # dry <label> <aws command ...>
  local label="$1"; shift
  local out; out=$("$@" --dry-run 2>&1)
  if grep -q 'DryRunOperation' <<<"$out"; then pass "$label"; else fail "$label" "$(head -c 300 <<<"$out")"; fi
}

echo "== Who am I"
aws sts get-caller-identity --output table || { echo "No credentials — run this in CloudShell"; exit 1; }

echo "== Region ${REGION}: network and image"
VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text 2>&1)
[[ "$VPC" == vpc-* ]] && pass "Default VPC: $VPC" || fail "Default VPC" "$VPC (no default VPC: create one, or set subnets by hand)"
SUBNET=$(aws ec2 describe-subnets --region "$REGION" --filters Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text 2>&1)
[[ "$SUBNET" == subnet-* ]] && pass "Default subnet: $SUBNET" || fail "Default subnet" "$SUBNET"
AMI=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>&1)
[[ "$AMI" == ami-* ]] && pass "Ubuntu 24.04 AMI visible: $AMI" || fail "Ubuntu 24.04 AMI" "$AMI"

echo "== Launch permissions (dry run: exactly what the lab launches)"
for TYPE in t3.small t3.medium; do
  dry "RunInstances ${TYPE}, 20 GiB gp3, public IP, Name tag" \
    aws ec2 run-instances --region "$REGION" --image-id "$AMI" --instance-type "$TYPE" --count 1 \
      --network-interfaces "DeviceIndex=0,SubnetId=${SUBNET},AssociatePublicIpAddress=true" \
      --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}' \
      --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=zg527-preflight}]'
done

echo "== Security group permissions"
dry "CreateSecurityGroup" aws ec2 create-security-group --region "$REGION" --group-name zg527-preflight-dry --description "dry run" --vpc-id "$VPC"
if [[ -n "$SG_ID" ]]; then
  dry "AuthorizeSecurityGroupIngress (self-reference, all traffic) on $SG_ID" \
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
      --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=${SG_ID}}]"
  dry "AuthorizeSecurityGroupIngress (tcp 30080 from 0.0.0.0/0) on $SG_ID" \
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
      --ip-permissions 'IpProtocol=tcp,FromPort=30080,ToPort=30080,IpRanges=[{CidrIp=0.0.0.0/0}]'
else
  echo "  SKIP  rule edits (set SG_ID=sg-... to test them)"
fi

echo "== vCPU quota (Running On-Demand Standard instances, L-1216C47A)"
Q=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text 2>&1)
if [[ "$Q" =~ ^[0-9.]+$ ]]; then
  USED=$(aws ec2 describe-instances --region "$REGION" --filters Name=instance-state-name,Values=pending,running \
    --query 'Reservations[].Instances[].CpuOptions.[CoreCount,ThreadsPerCore]' --output text 2>/dev/null | awk '{s+=$1*$2} END {print s+0}')
  FREE=$(awk -v q="$Q" -v u="$USED" 'BEGIN{print int(q-u)}')
  if (( FREE >= NEED_VCPU )); then pass "Quota ${Q%.*} vCPU, ${USED} in use, ${FREE} free (need ${NEED_VCPU})"
  else fail "vCPU quota" "quota ${Q%.*}, in use ${USED}, free ${FREE}; the lab needs ${NEED_VCPU}. Request an increase or run the clusters one after the other."; fi
else
  fail "Read vCPU quota" "$(head -c 200 <<<"$Q") — check Service Quotas in the console instead"
fi

echo "== Network ACLs on ${SUBNET} (custom DENY rules can block VXLAN/UDP between nodes)"
DENIES=$(aws ec2 describe-network-acls --region "$REGION" --filters Name=association.subnet-id,Values="$SUBNET" \
  --query 'NetworkAcls[0].Entries[?RuleAction==`deny` && RuleNumber!=`32767`].[Egress,RuleNumber,Protocol,CidrBlock,PortRange.From,PortRange.To]' --output text 2>&1)
if [[ -z "$DENIES" ]]; then pass "No custom deny rules"; else fail "Custom NACL deny rules found" "$DENIES"; fi

echo
if (( FAILS == 0 )); then echo "RESULT: all permission checks passed. Next: part 2 (node-check.sh on two test instances)."
else echo "RESULT: ${FAILS} check(s) failed. Show the FAIL lines to whoever administers the BITS AWS organisation."; fi
