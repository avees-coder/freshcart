#!/usr/bin/env bash
# =============================================================================
# ZG527 Cloud Computing - BITS AWS lab permission audit
#
# Run in AWS CloudShell, opened from the BITS lab portal with a STUDENT-LEVEL ID.
# (Lives in infra/preflight/. Wider than aws-permissions-check.sh: it also covers the module 5-8 labs.)
#   bash bits-permission-audit.sh                full audit (launches one t3a.nano for ~4 min)
#   bash bits-permission-audit.sh --no-instance  skip the live-instance tests
#   bash bits-permission-audit.sh --cleanup      remove leftovers from an interrupted run
#
# Every resource it creates is named zg527-audit-* and is deleted before it exits.
# Expected cost: well under USD 0.01.   Expected run time: 5-7 minutes.
# Results are printed and written to ~/bits-audit-<timestamp>.csv
#
# Status meanings
#   PASS        the action is allowed
#   DENIED      the action is blocked   -> goes on the request list for BITS
#   RESTRICTED  an action that SHOULD be blocked is blocked (e.g. other regions)
#   OPEN        an action that should be blocked is allowed (informational)
#   CHECK       inconclusive - read the detail line
#   LOW         a quota is lower than the lab needs
# =============================================================================
set -uo pipefail

REGION="${REGION:-ap-south-1}"
P="zg527-audit"
KEY="/tmp/${P}-key"
OUT="$HOME/bits-audit-$(date +%Y%m%d-%H%M%S).csv"
MODE="full"
for a in "$@"; do
  case "$a" in
    --no-instance) MODE="noinstance" ;;
    --cleanup)     MODE="cleanup" ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 1 ;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found - run this in AWS CloudShell"; exit 1; }
export AWS_PAGER=""
export AWS_DEFAULT_REGION="$REGION"

ACCOUNT=""; VPC=""; SUBNET=""; AZ=""; AMI=""; SGID=""; IID=""; VOL=""
KEYOK=0

# ---------------------------------------------------------------- cleanup ----
cleanup_all() {
  local ids sg s arn
  ids=$(aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=$P" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
  if [ -n "$ids" ] && [ "$ids" != "None" ]; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $ids >/dev/null 2>&1
    # shellcheck disable=SC2086
    timeout 300 aws ec2 wait instance-terminated --instance-ids $ids >/dev/null 2>&1
  fi
  sg=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${P}-sg" \
       --query 'SecurityGroups[].GroupId' --output text 2>/dev/null)
  for s in $sg; do
    if [ "$s" != "None" ]; then aws ec2 delete-security-group --group-id "$s" >/dev/null 2>&1; fi
  done
  aws ec2 delete-key-pair --key-name "${P}-key" >/dev/null 2>&1
  aws ec2 delete-launch-template --launch-template-name "${P}-lt" >/dev/null 2>&1
  aws cloudformation delete-stack --stack-name "${P}-cfn" >/dev/null 2>&1
  aws cloudwatch delete-alarms --alarm-names "${P}-alarm" >/dev/null 2>&1
  aws logs delete-log-group --log-group-name "/${P}" >/dev/null 2>&1
  arn=$(aws elbv2 describe-target-groups --names "${P}-tg" \
        --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    aws elbv2 delete-target-group --target-group-arn "$arn" >/dev/null 2>&1
  fi
  aws iam detach-role-policy --role-name "${P}-role" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1
  aws iam remove-role-from-instance-profile --instance-profile-name "${P}-ip" \
      --role-name "${P}-role" >/dev/null 2>&1
  aws iam delete-instance-profile --instance-profile-name "${P}-ip" >/dev/null 2>&1
  aws iam delete-role --role-name "${P}-role" >/dev/null 2>&1
  if [ -n "${ACCOUNT:-}" ]; then
    aws budgets delete-budget --account-id "$ACCOUNT" --budget-name "${P}-budget" >/dev/null 2>&1
  fi
  rm -f "$KEY" "$KEY.pub"
  return 0
}

verify_clean() {
  local left
  left=$(aws ec2 describe-instances \
         --filters "Name=tag:Project,Values=$P" \
                   "Name=instance-state-name,Values=pending,running,stopping,stopped" \
         --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
  if [ -n "$left" ] && [ "$left" != "None" ]; then
    echo "WARNING: instance(s) still present: $left"
    echo "         terminate them in the EC2 console (tag Project = $P)."
  else
    echo "Cleanup verified: no audit instances left running."
  fi
}

if [ "$MODE" = cleanup ]; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
  echo "Removing leftovers named ${P}-* in $REGION ..."
  cleanup_all
  verify_clean
  exit 0
fi

trap 'cleanup_all' EXIT

# ---------------------------------------------------------------- harness ----
declare -A COUNT=()
BAD=()
LAST_OUT=""; LAST_RC=0
DENY_RE='UnauthorizedOperation|AccessDenied|not authorized|AuthorizationError|explicit deny|Forbidden|OptInRequired|SubscriptionRequired|UnrecognizedClientException'

echo "id,priority,area,expected,status,check,detail" > "$OUT"

record() {  # id prio area expect status desc detail
  local id="$1" prio="$2" area="$3" expect="$4" status="$5" desc="$6" detail="${7:-}"
  detail=$(printf '%s' "$detail" | head -n1 | tr -d '\r"' | tr ',' ';' | cut -c1-120)
  printf '%-4s %-3s %-10s %-9s %s\n' "$id" "$prio" "$status" "$area" "$desc"
  if [ -n "$detail" ] && [ "$status" != PASS ]; then printf '        -> %s\n' "$detail"; fi
  printf '%s,%s,%s,%s,%s,"%s","%s"\n' "$id" "$prio" "$area" "$expect" "$status" "$desc" "$detail" >> "$OUT"
  COUNT[$status]=$(( ${COUNT[$status]:-0} + 1 ))
  case "$status" in DENIED|CHECK|OPEN|LOW) BAD+=("$prio $id $status $desc") ;; esac
}

check() {  # id prio area expect desc command...
  local id="$1" prio="$2" area="$3" expect="$4" desc="$5" verdict status
  shift 5
  LAST_OUT=$("$@" 2>&1); LAST_RC=$?
  if grep -Eqi 'ExpiredToken|token included in the request is expired|credentials.*expired' <<<"$LAST_OUT"; then
    echo
    echo "SESSION EXPIRED at $id - the lab portal session timed out (60 min limit)."
    echo "Relaunch the lab from the portal, reopen CloudShell, then run:"
    echo "    bash $0 --cleanup"
    echo "and start the audit again."
    exit 2
  fi
  if   grep -q 'DryRunOperation' <<<"$LAST_OUT";  then verdict=allowed
  elif grep -Eqi "$DENY_RE" <<<"$LAST_OUT";       then verdict=denied
  elif [ "$LAST_RC" -eq 0 ];                      then verdict=allowed
  else verdict=other; fi
  if [ "$expect" = allow ]; then
    case "$verdict" in allowed) status=PASS ;; denied) status=DENIED ;; *) status=CHECK ;; esac
  else
    case "$verdict" in denied) status=RESTRICTED ;; allowed) status=OPEN ;; *) status=CHECK ;; esac
  fi
  record "$id" "$prio" "$area" "$expect" "$status" "$desc" "$LAST_OUT"
}

skip() {  # id prio area desc reason
  record "$1" "$2" "$3" allow CHECK "$4" "skipped: $5"
}

info() { printf '   . %s\n' "$*"; }

wait_for() {  # wait_for <ec2 wait name>
  timeout 300 aws ec2 wait "$1" --instance-ids "$IID" >/dev/null 2>&1
}

delete_sg() {
  local out rc n
  for n in 1 2 3 4 5 6; do
    out=$(aws ec2 delete-security-group --group-id "$SGID" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
    grep -q DependencyViolation <<<"$out" || break
    sleep 10
  done
  echo "$out"; return "$rc"
}

mk_instance_profile() {
  aws iam create-instance-profile --instance-profile-name "${P}-ip" &&
  aws iam add-role-to-instance-profile --instance-profile-name "${P}-ip" --role-name "${P}-role"
}

# ------------------------------------------------------------------- start ---
echo "ZG527 BITS AWS permission audit   region=$REGION   mode=$MODE"
echo "Results file: $OUT"
echo

echo "== Session and identity"
check S01 P1 session allow "Credentials work (sts:GetCallerIdentity)" \
      aws sts get-caller-identity --query Account --output text
if [ "$LAST_RC" -ne 0 ]; then
  echo
  echo "No working credentials in this shell. That is itself the first finding:"
  echo "CloudShell cannot reach the account with this role. Stop here and raise it with BITS."
  exit 1
fi
ACCOUNT="$LAST_OUT"
info "Account $ACCOUNT, caller: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
check S02 P4 session deny "Other regions are blocked (describe-instances in us-east-1)" \
      aws ec2 describe-instances --region us-east-1 --max-items 1

echo; echo "== EC2 set-up for the Kubernetes lab"
check E01 P1 ec2 allow "List instances" aws ec2 describe-instances --max-items 1
check E02 P1 ec2 allow "Find the default VPC" \
      aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text
VPC="$LAST_OUT"
if [ "$LAST_RC" -ne 0 ] || [ "$VPC" = None ] || [ -z "$VPC" ]; then
  info "No usable default VPC found - network tests below will be skipped or inconclusive."
  VPC=""
fi
check E03 P1 ec2 allow "Find a subnet in the default VPC" \
      aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC:-none}" \
      --query 'Subnets[0].SubnetId' --output text
SUBNET="$LAST_OUT"; [ "$LAST_RC" -eq 0 ] || SUBNET=""
if [ -n "$SUBNET" ] && [ "$SUBNET" != None ]; then
  AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET" --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null)
else
  SUBNET=""
fi

check E04 P1 ssm allow "Resolve the Ubuntu 24.04 AMI (public SSM parameter)" \
      aws ssm get-parameter \
      --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
      --query Parameter.Value --output text
AMI=""; [ "$LAST_RC" -eq 0 ] && AMI="$LAST_OUT"
if [ -z "$AMI" ]; then
  AMI=$(aws ec2 describe-images --owners 099720109477 \
        --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null)
  [ "$AMI" = None ] && AMI=""
  info "SSM lookup failed; fallback describe-images gave: ${AMI:-nothing}"
fi
AMI_TEST="${AMI:-ami-00000000000000000}"
SUBNET_TEST="${SUBNET:-subnet-00000000}"
info "AMI under test: $AMI_TEST"

check E05 P1 ec2 allow "Launch permitted: t3a.small (dry run)" \
      aws ec2 run-instances --dry-run --image-id "$AMI_TEST" --instance-type t3a.small \
      --subnet-id "$SUBNET_TEST" --count 1
check E06 P1 ec2 allow "Launch permitted: t3a.medium (dry run)" \
      aws ec2 run-instances --dry-run --image-id "$AMI_TEST" --instance-type t3a.medium \
      --subnet-id "$SUBNET_TEST" --count 1
check E07 P4 ec2 deny "t3a.large is blocked, as the portal states (dry run)" \
      aws ec2 run-instances --dry-run --image-id "$AMI_TEST" --instance-type t3a.large \
      --subnet-id "$SUBNET_TEST" --count 1
check E08 P4 ec2 deny "t3.small (old scripts) is blocked (dry run)" \
      aws ec2 run-instances --dry-run --image-id "$AMI_TEST" --instance-type t3.small \
      --subnet-id "$SUBNET_TEST" --count 1

check Q01 P1 quota allow "Read the EC2 vCPU quota (L-1216C47A)" \
      aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
      --query Quota.Value --output text
if [ "$LAST_RC" -eq 0 ]; then
  info "On-demand standard vCPU quota: $LAST_OUT   (cluster needs 6, plus headroom for resize/AMI tests)"
  if awk -v q="$LAST_OUT" 'BEGIN{exit !(q+0 < 6)}'; then
    record Q02 P1 quota allow LOW "vCPU quota is at least 6" "quota is $LAST_OUT"
  else
    record Q02 P1 quota allow PASS "vCPU quota is at least 6" ""
  fi
fi

if command -v ssh-keygen >/dev/null 2>&1; then
  rm -f "$KEY" "$KEY.pub"
  ssh-keygen -q -t ed25519 -N '' -f "$KEY" >/dev/null 2>&1
  check E09 P1 ec2 allow "Import an SSH key pair" \
        aws ec2 import-key-pair --key-name "${P}-key" --public-key-material "fileb://$KEY.pub"
  [ "$LAST_RC" -eq 0 ] && KEYOK=1
else
  skip E09 P1 ec2 "Import an SSH key pair" "ssh-keygen not available in this shell"
fi

if [ -n "$VPC" ]; then
  check E10 P1 ec2 allow "Create a security group" \
        aws ec2 create-security-group --group-name "${P}-sg" --description "zg527 audit" \
        --vpc-id "$VPC" --query GroupId --output text
  [ "$LAST_RC" -eq 0 ] && SGID="$LAST_OUT"
else
  skip E10 P1 ec2 "Create a security group" "no default VPC"
fi
if [[ "$SGID" =~ ^sg- ]]; then
  check E11 P1 ec2 allow "Tag resources (ec2:CreateTags)" \
        aws ec2 create-tags --resources "$SGID" --tags "Key=Project,Value=$P"
  check E12 P1 ec2 allow "Open TCP 22 to 0.0.0.0/0 (SSH from a laptop)" \
        aws ec2 authorize-security-group-ingress --group-id "$SGID" --protocol tcp --port 22 --cidr 0.0.0.0/0
  check E13 P1 ec2 allow "Open UDP 8472 between group members (Flannel VXLAN)" \
        aws ec2 authorize-security-group-ingress --group-id "$SGID" \
        --ip-permissions "IpProtocol=udp,FromPort=8472,ToPort=8472,UserIdGroupPairs=[{GroupId=$SGID}]"
  check E14 P1 ec2 allow "Open TCP 30080 to 0.0.0.0/0 (FreshCart NodePort)" \
        aws ec2 authorize-security-group-ingress --group-id "$SGID" --protocol tcp --port 30080 --cidr 0.0.0.0/0
else
  for t in "E11 Tag resources (ec2:CreateTags)" "E12 Open TCP 22 to 0.0.0.0/0" \
           "E13 Open UDP 8472 between group members" "E14 Open TCP 30080 to 0.0.0.0/0"; do
    skip "${t%% *}" P1 ec2 "${t#* }" "no security group was created"
  done
fi

check E15 P2 ec2 allow "Create a launch template (module 5.3)" \
      aws ec2 create-launch-template --launch-template-name "${P}-lt" \
      --launch-template-data '{"InstanceType":"t3a.small"}'
check E16 P2 ec2 allow "Create an EBS volume (dry run)" \
      aws ec2 create-volume --dry-run --size 1 --availability-zone "${AZ:-ap-south-1a}"

echo; echo "== IAM (instance profiles for Session Manager / CloudWatch agent)"
check M01 P2 iam allow "List IAM roles" aws iam list-roles --max-items 50 --query 'Roles[].RoleName' --output text
if [ "$LAST_RC" -eq 0 ]; then
  info "Roles that look reusable (name contains Lab or Lambda): $(tr '\t' '\n' <<<"$LAST_OUT" | grep -Ei 'lab|lambda' | head -5 | tr '\n' ' ')"
fi
check M02 P2 iam allow "List instance profiles" \
      aws iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' --output text
[ "$LAST_RC" -eq 0 ] && info "Existing instance profiles: ${LAST_OUT:-none}"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
check M03 P3 iam allow "Create an IAM role" \
      aws iam create-role --role-name "${P}-role" --assume-role-policy-document "$TRUST"
ROLEOK=0; [ "$LAST_RC" -eq 0 ] && ROLEOK=1
if [ "$ROLEOK" -eq 1 ]; then
  check M04 P3 iam allow "Attach an AWS managed policy to the role" \
        aws iam attach-role-policy --role-name "${P}-role" \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  check M05 P3 iam allow "Create an instance profile and add the role" mk_instance_profile
else
  skip M04 P3 iam "Attach an AWS managed policy to the role" "role was not created"
  skip M05 P3 iam "Create an instance profile and add the role" "role was not created"
fi

if [ "$MODE" = full ]; then
  echo; echo "== Live instance lifecycle (one t3a.nano, a few minutes)"
  if [ -z "$AMI" ] || [ -z "$SUBNET" ] || ! [[ "$SGID" =~ ^sg- ]]; then
    for t in "I01 Launch t3a.nano with SG and tag-on-create" "I02 Stop instance (end-of-session routine)" \
             "I03 Resize stopped instance t3a.nano to t3a.small (vertical scaling)" "I04 Start instance" \
             "I05 EC2 Instance Connect key push" "I06 Read Session Manager inventory" \
             "I07 Create AMI (dry run)" "I08 Create snapshot (dry run)" "I09 Modify volume type (dry run)" \
             "I10 Attach instance profile to instance" "T01 Terminate instance"; do
      skip "${t%% *}" P1 ec2 "${t#* }" "AMI, subnet or security group missing"
    done
  else
    KEYARGS=(); [ "$KEYOK" -eq 1 ] && KEYARGS=(--key-name "${P}-key")
    check I01 P1 ec2 allow "Launch t3a.nano with SG and tag-on-create" \
          aws ec2 run-instances --image-id "$AMI" --instance-type t3a.nano --subnet-id "$SUBNET" \
          --security-group-ids "$SGID" ${KEYARGS[@]+"${KEYARGS[@]}"} --count 1 \
          --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$P}]" \
          --query 'Instances[0].InstanceId' --output text
    if [ "$LAST_RC" -eq 0 ] && [[ "$LAST_OUT" =~ ^i- ]]; then
      IID="$LAST_OUT"
      wait_for instance-running
      VOL=$(aws ec2 describe-instances --instance-ids "$IID" \
            --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text 2>/dev/null)
      check I05 P2 ec2 allow "EC2 Instance Connect key push (browser/CLI access without a key pair)" \
            aws ec2-instance-connect send-ssh-public-key --instance-id "$IID" \
            --instance-os-user ubuntu --ssh-public-key "file://$KEY.pub"
      check I06 P3 ssm allow "Read Session Manager inventory" aws ssm describe-instance-information --max-items 1
      check I07 P2 ec2 allow "Create AMI (dry run)" aws ec2 create-image --dry-run --instance-id "$IID" --name "${P}-img"
      check I08 P2 ec2 allow "Create snapshot (dry run)" aws ec2 create-snapshot --dry-run --volume-id "$VOL"
      check I09 P3 ec2 allow "Modify volume type gp2 to gp3 (dry run)" \
            aws ec2 modify-volume --dry-run --volume-id "$VOL" --volume-type gp3
      if [ "$ROLEOK" -eq 1 ]; then
        sleep 12   # IAM propagation
        check I10 P3 ec2 allow "Attach instance profile to instance (needs iam:PassRole)" \
              aws ec2 associate-iam-instance-profile --instance-id "$IID" --iam-instance-profile "Name=${P}-ip"
      else
        skip I10 P3 ec2 "Attach instance profile to instance" "no instance profile was created"
      fi
      # CloudWatch alarm on this instance (monitoring lab)
      check W02 P2 monitoring allow "Create a CloudWatch alarm on instance CPU" \
            aws cloudwatch put-metric-alarm --alarm-name "${P}-alarm" --namespace AWS/EC2 \
            --metric-name CPUUtilization --statistic Average --period 300 --evaluation-periods 1 \
            --threshold 80 --comparison-operator GreaterThanThreshold \
            --dimensions "Name=InstanceId,Value=$IID"
      check I02 P1 ec2 allow "Stop instance (end-of-session routine)" \
            aws ec2 stop-instances --instance-ids "$IID" --query 'StoppingInstances[0].CurrentState.Name' --output text
      wait_for instance-stopped
      check I03 P2 ec2 allow "Resize stopped instance t3a.nano to t3a.small (vertical scaling)" \
            aws ec2 modify-instance-attribute --instance-id "$IID" --instance-type '{"Value":"t3a.small"}'
      check I04 P1 ec2 allow "Start instance" \
            aws ec2 start-instances --instance-ids "$IID" --query 'StartingInstances[0].CurrentState.Name' --output text
      wait_for instance-running
      check T01 P1 ec2 allow "Terminate instance" \
            aws ec2 terminate-instances --instance-ids "$IID" --query 'TerminatingInstances[0].CurrentState.Name' --output text
      wait_for instance-terminated
    else
      for t in "I02 Stop instance (end-of-session routine)" \
               "I03 Resize stopped instance t3a.nano to t3a.small (vertical scaling)" "I04 Start instance" \
               "I05 EC2 Instance Connect key push" "I06 Read Session Manager inventory" \
               "I07 Create AMI (dry run)" "I08 Create snapshot (dry run)" "I09 Modify volume type (dry run)" \
               "I10 Attach instance profile to instance" "T01 Terminate instance"; do
        skip "${t%% *}" P1 ec2 "${t#* }" "the test instance did not launch"
      done
    fi
  fi
fi

if [[ "$SGID" =~ ^sg- ]]; then
  check E17 P2 ec2 allow "Delete the security group" delete_sg
fi
[ "$KEYOK" -eq 1 ] && check E18 P2 ec2 allow "Delete the key pair" aws ec2 delete-key-pair --key-name "${P}-key"

echo; echo "== Infrastructure as Code (module 5.6)"
check C01 P2 cfn allow "List CloudFormation stacks" aws cloudformation list-stacks --max-items 1
check C02 P2 cfn allow "Create a stack (free WaitConditionHandle template)" \
      aws cloudformation create-stack --stack-name "${P}-cfn" \
      --template-body '{"Resources":{"H":{"Type":"AWS::CloudFormation::WaitConditionHandle"}}}'
if [ "$LAST_RC" -eq 0 ]; then
  check C03 P2 cfn allow "Stack reaches CREATE_COMPLETE" \
        timeout 180 aws cloudformation wait stack-create-complete --stack-name "${P}-cfn"
  check C04 P2 cfn allow "Delete the stack" aws cloudformation delete-stack --stack-name "${P}-cfn"
else
  skip C03 P2 cfn "Stack reaches CREATE_COMPLETE" "stack was not created"
  skip C04 P2 cfn "Delete the stack" "stack was not created"
fi

echo; echo "== Spend visibility and guard rails (the USD 35 credit)"
check K01 P2 cost allow "Read spend (Cost Explorer)" \
      aws ce get-cost-and-usage --time-period "Start=$(date -u -d '3 days ago' +%F),End=$(date -u +%F)" \
      --granularity DAILY --metrics UnblendedCost
check K02 P2 cost allow "Read budgets" aws budgets describe-budgets --account-id "$ACCOUNT" --max-results 1
check K03 P2 cost allow "Create a budget with an alert" \
      aws budgets create-budget --account-id "$ACCOUNT" --budget \
      "{\"BudgetName\":\"${P}-budget\",\"BudgetLimit\":{\"Amount\":\"30\",\"Unit\":\"USD\"},\"TimeUnit\":\"MONTHLY\",\"BudgetType\":\"COST\"}"

echo; echo "== Monitoring and audit (modules 7-8)"
check W01 P2 monitoring allow "Read EC2 metrics (CloudWatch)" aws cloudwatch list-metrics --namespace AWS/EC2 --max-items 1
check W03 P3 monitoring allow "Create a log group" aws logs create-log-group --log-group-name "/${P}"
check W04 P2 monitoring allow "Read the audit trail (CloudTrail LookupEvents)" aws cloudtrail lookup-events --max-results 1

echo; echo "== Optional: serverless, scaling and load balancing (stretch labs)"
check L01 P4 serverless allow "List Lambda functions" aws lambda list-functions --max-items 1
check L02 P4 serverless allow "List API Gateway REST APIs" aws apigateway get-rest-apis --limit 1
check A01 P4 scaling allow "List Auto Scaling groups" aws autoscaling describe-auto-scaling-groups --max-items 1
check A02 P4 scaling allow "List load balancers" aws elbv2 describe-load-balancers --page-size 1
if [ -n "$VPC" ]; then
  check A03 P4 scaling allow "Create a target group (free)" \
        aws elbv2 create-target-group --name "${P}-tg" --protocol HTTP --port 80 --vpc-id "$VPC"
else
  skip A03 P4 scaling "Create a target group (free)" "no default VPC"
fi

# ----------------------------------------------------------------- summary ---
echo; echo "== Cleaning up"
cleanup_all
verify_clean
trap - EXIT

echo
echo "================ SUMMARY ================"
for s in PASS DENIED RESTRICTED OPEN CHECK LOW; do printf '%-11s %s\n' "$s" "${COUNT[$s]:-0}"; done
if [ "${#BAD[@]}" -gt 0 ]; then
  echo
  echo "Needs attention (P1 = Kubernetes lab cannot run without it):"
  printf '%s\n' "${BAD[@]}" | sort
fi
echo
echo "Results saved to: $OUT"
echo "Download it: CloudShell menu > Actions > Download file > $OUT"
echo "Next: launch two throwaway t3a.small instances and run node-check.sh (sizing, egress, listen/probe) - runbook P0.2-P0.5."
