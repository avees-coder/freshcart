#!/usr/bin/env bash
# =============================================================================
# ZG527 lab launcher: creates, inspects, stops/starts and tears down the three EC2
# instances (1 control plane + 2 workers) for the Kubernetes demo and lab.
#
# Run in AWS CloudShell or Git Bash/Linux/macOS with the AWS CLI v2 configured,
# as the identity that owns the lab (not root, if you can avoid it).
#
#   bash infra/aws-lab.sh up       create the security group + 3 instances (idempotent)
#   bash infra/aws-lab.sh status   table of names, states and IPs (+ inventory file)
#   bash infra/aws-lab.sh stop     stop all lab instances (EBS still billed)  <- end of EVERY sitting
#   bash infra/aws-lab.sh start    start them again (public IPs CHANGE)
#   bash infra/aws-lab.sh down     terminate all lab instances (asks to confirm)
#
# BITS lab account facts this script is built for: region ap-south-1 only; instance types
# t3a.nano/micro/small/medium only; USD 35 credit; the portal session ends after 60 min and
# does NOT stop running instances. So every node gets an AUTO-STOP timer (see AUTOSTOP_HOURS).
#
# Settings (environment variables):
#   KEY_NAME     EC2 key pair in THIS region                  (required for up)
#   MY_IP        your laptop's public IP, e.g. 122.167.119.77 (required in CloudShell)
#   REGION       default: the shell's region, else ap-south-1
#   REPO_URL     e.g. https://github.com/<owner>/freshcart.git - cloned to ~/freshcart on every node
#   CREATE_KEY=1 create KEY_NAME (ed25519) if missing; private key saved to ~/KEY_NAME.pem
#   OPEN_TO_ALL=1  storefront port 30080 open to 0.0.0.0/0 instead of MY_IP
#   AUTOSTOP_HOURS  nodes power themselves off this many hours after every boot (default 4; 0 = off)
#   DELETE_SG=1  with 'down': also delete the security group
#   LOG_DIR      where run logs go (default ~/zg527-logs); LOG=0 disables logging
#
# Example (CloudShell, ap-south-1):
#   KEY_NAME=zg527-aps1 MY_IP=122.167.119.77 \
#   REPO_URL=https://github.com/<owner>/freshcart.git bash infra/aws-lab.sh up
# =============================================================================
set -euo pipefail
shopt -s inherit_errexit   # make failures inside $(...) stop the script too

REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$(command aws configure get region 2>/dev/null || true)}}}"
REGION="${REGION:-ap-south-1}"
AUTOSTOP_HOURS="${AUTOSTOP_HOURS:-4}"
PROJECT=zg527
K8S_SG_NAME=zg527-k8s
INVENTORY="${HOME}/zg527-inventory-${REGION}.txt"

# ---- run log: everything printed (including AWS CLI errors) is also written to a file.
# The private key from CREATE_KEY goes straight to its .pem file and never reaches the log.
if [[ "${LOG:-1}" == 1 && -n "${1:-}" ]]; then
  LOG_DIR="${LOG_DIR:-${HOME}/zg527-logs}"
  mkdir -p "$LOG_DIR"
  LOG_FILE="${LOG_DIR}/aws-lab-${1}-${REGION}-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "# aws-lab.sh ${1}  |  $(date -Is)  |  region=${REGION} autostop=${AUTOSTOP_HOURS}h key=${KEY_NAME:-} my_ip=${MY_IP:-} repo=${REPO_URL:-}"
  # shellcheck disable=SC2154  # rc is assigned inside the trap string
  trap 'rc=$?; echo "# exit code ${rc}  |  $(date -Is)  |  log: ${LOG_FILE}"; sleep 0.2' EXIT
fi

# name | type | cluster | security group name   (BITS lab allows only t3a.nano/micro/small/medium)
CP_TYPE="${CP_TYPE:-t3a.medium}"
W_TYPE="${W_TYPE:-t3a.small}"
NODES=(
  "k8s-cp|${CP_TYPE}|k8s|${K8S_SG_NAME}"
  "k8s-w1|${W_TYPE}|k8s|${K8S_SG_NAME}"
  "k8s-w2|${W_TYPE}|k8s|${K8S_SG_NAME}"
)

aws() { command aws --region "$REGION" "$@"; }
say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
info() { printf '   ..    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
preflight() {
  say "Identity and region"
  local arn; arn=$(aws sts get-caller-identity --query Arn --output text) \
    || die "no AWS credentials (CloudShell: see runbook 2B.1; laptop: aws configure / aws configure sso)"
  ok "caller: $arn"
  ok "region: $REGION"
  [[ "$arn" == *":root" ]] && info "WARNING: running as the account ROOT user — prefer an IAM admin user (runbook 2B.2)"
  [[ "$AUTOSTOP_HOURS" =~ ^[0-9]+$ ]] || die "AUTOSTOP_HOURS must be a whole number of hours (0 = off)"
  return 0
}

find_network() {
  say "Network"
  VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  [[ "$VPC" == vpc-* ]] || die "no default VPC in $REGION (create one: VPC console > Actions > Create default VPC)"
  ok "default VPC: $VPC"

  # Not every Availability Zone offers every instance type: pick one that has both.
  # If the lab policy blocks DescribeInstanceTypeOfferings, fall back to the first default subnet.
  local azs
  azs=$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
          --filters "Name=instance-type,Values=${CP_TYPE},${W_TYPE}" \
          --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null | tr '\t' '\n' | sort | uniq -c | awk '$1==2 {print $2}') || azs=""
  SUBNET=""; AZ=""
  while read -r az subnet; do
    if [[ -z "$azs" ]] || grep -qx "$az" <<<"$azs"; then SUBNET="$subnet"; AZ="$az"; break; fi
  done < <(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
             --query 'sort_by(Subnets,&AvailabilityZone)[].[AvailabilityZone,SubnetId]' --output text)
  [[ -n "$SUBNET" ]] || die "no default subnet in an AZ offering both ${CP_TYPE} and ${W_TYPE}"
  [[ -n "$azs" ]] || info "could not read instance-type offerings (policy?) - using the first default subnet"
  ok "subnet: $SUBNET ($AZ) - all three nodes go here"

  AMI=$(aws ec2 describe-images --owners 099720109477 \
          --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" "Name=state,Values=available" \
          --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null) || AMI=""
  if [[ "$AMI" != ami-* ]]; then
    AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
            --query Parameter.Value --output text 2>/dev/null) || AMI=""
  fi
  [[ "$AMI" == ami-* ]] || die "Ubuntu 24.04 AMI not found in $REGION (describe-images and the SSM parameter both failed)"
  ok "AMI: $AMI (Canonical Ubuntu 24.04 LTS, amd64)"
}

ensure_key() {
  say "Key pair"
  [[ -n "${KEY_NAME:-}" ]] || die "set KEY_NAME (a key pair in $REGION; key pairs are per region — e.g. zg527-use1)"
  local fp
  fp=$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" --query 'KeyPairs[0].[KeyType,KeyFingerprint]' --output text 2>/dev/null || true)
  if [[ -z "$fp" ]]; then
    [[ "${CREATE_KEY:-0}" == 1 ]] || die "key pair '$KEY_NAME' does not exist in $REGION (create it in the console, or re-run with CREATE_KEY=1)"
    local pem="${HOME}/${KEY_NAME}.pem"
    [[ -e "$pem" ]] && die "$pem already exists — move it away first, it may belong to another region"
    aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
      --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=${PROJECT}}]" \
      --query KeyMaterial --output text > "$pem"
    chmod 400 "$pem"
    ok "created key pair $KEY_NAME; private key saved to $pem"
    info "CloudShell: Actions > Download file > $pem, then keep it in C:\\Users\\<you>\\.ssh (not OneDrive)"
    fp=$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" --query 'KeyPairs[0].[KeyType,KeyFingerprint]' --output text)
  fi
  ok "key pair $KEY_NAME — type/fingerprint: $fp"
  info "compare with your .pem:  ed25519 -> ssh-keygen -l -f <file>.pem   rsa -> runbook 2B.6"
}

my_cidr() {
  if [[ "${OPEN_TO_ALL:-0}" == 1 && "$1" == app ]]; then echo "0.0.0.0/0"; return; fi
  if [[ -z "${MY_IP:-}" ]]; then
    [[ -n "${AWS_EXECUTION_ENV:-}" && "${AWS_EXECUTION_ENV}" == *CloudShell* ]] && \
      die "set MY_IP to your LAPTOP's public IP (in CloudShell, auto-detect would return CloudShell's own IP). Find it at https://checkip.amazonaws.com from your laptop browser."
    MY_IP=$(curl -s -m 5 https://checkip.amazonaws.com | tr -d '[:space:]')
    [[ "$MY_IP" =~ ^[0-9.]+$ ]] || die "could not detect your public IP; set MY_IP"
    info "detected your public IP: $MY_IP" >&2
  fi
  [[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MY_IP must look like 122.167.119.77 (no /32, no brackets)"
  echo "${MY_IP}/32"
}

add_rule() {   # add_rule <sg-id> <ip-permissions> <label>  (idempotent)
  local err
  if err=$(aws ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "$2" 2>&1 >/dev/null); then
    ok "rule added: $3"
  elif grep -q 'InvalidPermission.Duplicate' <<<"$err"; then
    ok "rule present: $3"
  else
    die "could not add rule '$3' to $1: $err"
  fi
}

ensure_sg() {  # ensure_sg <name> <app-port>  -> echoes sg id on the last line
  local name="$1" port="$2" sg
  sg=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values="$name" \
         --query 'SecurityGroups[0].GroupId' --output text)
  if [[ "$sg" != sg-* ]]; then
    sg=$(aws ec2 create-security-group --group-name "$name" --description "ZG527 ${name} lab" --vpc-id "$VPC" \
           --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}}]" \
           --query GroupId --output text)
    ok "created $name: $sg" >&2
  else
    ok "found $name: $sg" >&2
  fi
  local ssh_cidr app_cidr
  ssh_cidr=$(my_cidr ssh) || exit 1
  app_cidr=$(my_cidr app) || exit 1
  add_rule "$sg" "IpProtocol=-1,UserIdGroupPairs=[{GroupId=${sg},Description=node-to-node}]" "all traffic from ${name} itself (6443, 10250, UDP 8472, NodePorts)" >&2
  add_rule "$sg" "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${ssh_cidr},Description=ssh-instructor}]" "ssh 22 from ${ssh_cidr}" >&2
  add_rule "$sg" "IpProtocol=tcp,FromPort=${port},ToPort=${port},IpRanges=[{CidrIp=${app_cidr},Description=storefront}]" "tcp ${port} from ${app_cidr}" >&2
  echo "$sg"
}

check_quota() {
  say "vCPU quota (L-1216C47A)"
  local need=0 n name type cluster sgname
  for n in "${NODES[@]}"; do
    IFS='|' read -r name type cluster sgname <<<"$n"
    [[ -n "$(instance_id "$name")" ]] && continue
    need=$((need + 2))   # every t3a size up to medium has 2 vCPU
  done
  if (( need == 0 )); then ok "nothing new to launch"; return; fi
  local quota used
  quota=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text 2>/dev/null || echo "")
  used=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running \
           --query 'Reservations[].Instances[].CpuOptions.[CoreCount,ThreadsPerCore]' --output text | awk '{s+=$1*$2} END {print s+0}')
  if [[ ! "$quota" =~ ^[0-9.]+$ ]]; then info "could not read the quota — continuing (launch will fail if it is too low)"; return; fi
  if (( ${quota%.*} - used < need )); then
    die "quota ${quota%.*} vCPU, ${used} in use, ${need} needed. Ask BITS for an increase to at least 12 (runbook 2B.4): 6 for the cluster, plus room to resize a node or build a second AMI."
  fi
  ok "quota ${quota%.*}, in use ${used}, launching ${need}"
}

instance_id() {  # live (not terminated) lab instance with this Name tag
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=tag:Project,Values=${PROJECT}" \
              Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

user_data() {  # user_data <hostname>
  local secs=$(( AUTOSTOP_HOURS * 3600 ))
  cat <<EOF
#cloud-config
# Sets a stable hostname BEFORE any cluster join (kubeadm registers nodes by hostname).
hostname: $1
fqdn: $1
preserve_hostname: false
manage_etc_hosts: true
package_update: true
packages: [git, tmux]
EOF
  if (( secs > 0 )); then
    cat <<EOF
write_files:
  - path: /etc/systemd/system/zg527-autostop.service
    permissions: "0644"
    content: |
      [Unit]
      Description=ZG527 lab auto-stop (credit protection)
      [Service]
      ExecStart=/bin/sh -c 'sleep ${secs} && /sbin/shutdown -h now "ZG527 auto-stop"'
      [Install]
      WantedBy=multi-user.target
EOF
  fi
  echo "runcmd:"
  if (( secs > 0 )); then
    echo "  - [systemctl, daemon-reload]"
    echo "  - [systemctl, enable, --now, zg527-autostop.service]"
  fi
  if [[ -n "${REPO_URL:-}" ]]; then
    echo "  - [sudo, -u, ubuntu, git, clone, \"${REPO_URL}\", /home/ubuntu/freshcart]"
  fi
  if (( secs == 0 )) && [[ -z "${REPO_URL:-}" ]]; then echo '  - ["true"]'; fi
}

launch_all() {
  say "Instances"
  local n name type cluster sgname sg id launched=()
  for n in "${NODES[@]}"; do
    IFS='|' read -r name type cluster sgname <<<"$n"
    id=$(instance_id "$name")
    if [[ -n "$id" ]]; then ok "$name exists ($id) - skipped"; continue; fi
    sg="$K8S_SG"
    local ud; ud=$(mktemp); user_data "$name" >"$ud"
    id=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$type" --key-name "$KEY_NAME" \
          --network-interfaces "DeviceIndex=0,SubnetId=${SUBNET},AssociatePublicIpAddress=true,Groups=${sg}" \
          --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
          --metadata-options HttpTokens=required,HttpEndpoint=enabled \
          --instance-initiated-shutdown-behavior stop \
          --user-data "file://${ud}" \
          --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}},{Key=Cluster,Value=${cluster}}]" \
            "ResourceType=volume,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}}]" \
          --query 'Instances[0].InstanceId' --output text)
    rm -f "$ud"
    ok "$name launched: $id ($type)"
    launched+=("$id")
  done
  if (( ${#launched[@]} )); then
    info "waiting for status checks to pass (2-5 minutes)..."
    aws ec2 wait instance-status-ok --instance-ids "${launched[@]}"
    ok "all new instances passed status checks"
    info "cloud-init may still be installing git / tmux / cloning for ~1 more minute"
    (( AUTOSTOP_HOURS > 0 )) && info "each node powers itself off ${AUTOSTOP_HOURS} h after boot (zg527-autostop); restart that timer to extend: sudo systemctl restart zg527-autostop"
  fi
}

status() {
  say "Lab instances in $REGION"
  local rows
  rows=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=${PROJECT}" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,InstanceType,Placement.AvailabilityZone,PrivateIpAddress,PublicIpAddress||`-`,KeyName]' \
    --output text | sort)
  if [[ -z "$rows" ]]; then info "none"; return; fi
  {
    printf '%-10s %-20s %-9s %-9s %-11s %-15s %-15s %s\n' NAME INSTANCE STATE TYPE AZ PRIVATE PUBLIC KEY
    printf '%s\n' "$rows" | awk '{printf "%-10s %-20s %-9s %-9s %-11s %-15s %-15s %s\n",$1,$2,$3,$4,$5,$6,$7,$8}'
    echo
    echo "SSH (from your laptop; keys are per region):"
    printf '%s\n' "$rows" | awk '$7!="-" && $7!="None" {printf "  ssh -i ~/.ssh/%s.pem ubuntu@%-15s # %s\n",$8,$7,$1}'
  } | tee "$INVENTORY"
  echo
  ok "saved to $INVENTORY (copy the IPs into runbook Appendix A)"
}

all_ids() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=${PROJECT}" Name=instance-state-name,Values="$1" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

do_stop() {
  local ids; ids=$(all_ids pending,running)
  [[ -n "$ids" ]] || { info "no running lab instances"; return; }
  # shellcheck disable=SC2086
  aws ec2 stop-instances --instance-ids $ids >/dev/null
  info "stopping: $ids"
  # shellcheck disable=SC2086
  aws ec2 wait instance-stopped --instance-ids $ids
  ok "stopped (only EBS storage is billed now; public IPs will change on start)"
}

do_start() {
  local ids; ids=$(all_ids stopped)
  [[ -n "$ids" ]] || { info "no stopped lab instances"; return; }
  # shellcheck disable=SC2086
  aws ec2 start-instances --instance-ids $ids >/dev/null
  info "starting: $ids"
  # shellcheck disable=SC2086
  aws ec2 wait instance-status-ok --instance-ids $ids
  ok "running - NEW public IPs below (each node's ${AUTOSTOP_HOURS} h auto-stop timer restarted at boot)"
  status
}

do_down() {
  local ids; ids=$(all_ids pending,running,stopping,stopped)
  if [[ -z "$ids" ]]; then info "no lab instances to terminate"
  else
    status
    printf '\nType "terminate" to permanently delete the instances above: '
    local answer; read -r answer
    [[ "$answer" == terminate ]] || die "aborted — nothing terminated"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $ids >/dev/null
    info "terminating: $ids"
    # shellcheck disable=SC2086
    aws ec2 wait instance-terminated --instance-ids $ids
    ok "terminated (root volumes deleted with them)"
  fi
  if [[ "${DELETE_SG:-0}" == 1 ]]; then
    local name sg
    for name in "$K8S_SG_NAME"; do
      sg=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$name" --query 'SecurityGroups[0].GroupId' --output text)
      if [[ "$sg" == sg-* ]]; then
        # a self-referencing rule blocks deletion: remove it first
        aws ec2 revoke-security-group-ingress --group-id "$sg" \
          --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=${sg}}]" >/dev/null 2>&1 || true
        aws ec2 delete-security-group --group-id "$sg" && ok "deleted $name ($sg)"
      fi
    done
  fi
  local left; left=$(aws ec2 describe-volumes --filters "Name=tag:Project,Values=${PROJECT}" Name=status,Values=available --query 'Volumes[].VolumeId' --output text)
  [[ -z "$left" ]] && ok "no leftover lab volumes" || info "leftover unattached volumes (delete them): $left"
}

# ----------------------------------------------------------------------------
case "${1:-}" in
  up)
    preflight; find_network; ensure_key; check_quota
    say "Security group"
    K8S_SG=$(ensure_sg "$K8S_SG_NAME" 30080 | tail -1) || exit 1
    [[ "$K8S_SG" == sg-* ]] || die "no security group resolved"
    launch_all
    status
    ;;
  status) preflight >/dev/null; status ;;
  stop)   preflight; do_stop ;;
  start)  preflight; do_start ;;
  down)   preflight; do_down ;;
  *) sed -n '2,32p' "$0"; exit 1 ;;
esac
