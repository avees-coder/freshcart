# Account preflight (run at least a week before class)

Checks that the AWS account (for example a BITS student lab account) does not block anything the
Kubernetes demo and the later labs need. Three parts:

1. `aws-permissions-check.sh` - in **AWS CloudShell**. Launches nothing. Uses `--dry-run`, which evaluates
   IAM policies and organisation SCPs, plus the vCPU quota and subnet network ACLs. Covers the Kubernetes lab.
2. `node-check.sh` - on **two throwaway t3a.small instances**. `sizing` (kubeadm minimums), `egress` (every
   download source, plus the Docker Hub pull allowance), real node-to-node TCP/UDP on the cluster ports, and
   inbound 30080 from your laptop.
3. `bits-permission-audit.sh` - in **AWS CloudShell**. The wider audit for the module 5-8 labs (CloudFormation,
   images/AMIs, snapshots, stop/start/resize, budgets and cost visibility, CloudWatch, CloudTrail, IAM roles).
   It creates and deletes small `zg527-audit-*` test resources and one t3a.nano for a few minutes (< USD 0.01),
   and writes a CSV to send to the account administrator. `--cleanup` removes leftovers if the portal session
   expired mid-run (the portal session lasts 60 minutes; the audit takes 5-7).

Full step-by-step procedure: runbook Section 2A (steps P0.1-P0.6). The permission matrix and the request to
BITS: `ZG527_BITS_AWS_Permission_Audit.docx`.

What dry-runs cannot catch: automatic "reaper" jobs that stop or delete instances after some hours,
and per-tag cost policies. Ask the account administrator about both. (In the BITS lab the portal session ends
after 60 minutes and does not stop running instances; that is what `infra/autostop.sh` is for.)
