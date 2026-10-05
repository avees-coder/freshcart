# Account preflight (run at least a week before class)

Checks that the AWS account (for example the BITS organisation account) does not block anything the
Swarm and Kubernetes demos need. Two parts:

1. `aws-permissions-check.sh` — in **AWS CloudShell**. Launches nothing. Uses `--dry-run`, which evaluates
   IAM policies and organisation SCPs, plus the vCPU quota and subnet network ACLs.
2. `node-check.sh` — on **two throwaway t3.small instances**. Real egress to every download source,
   real node-to-node TCP/UDP on the cluster ports, and inbound 80 / 30080 from your laptop.

Full step-by-step procedure: runbook Section 2A (steps P0.1–P0.6).

What dry-runs cannot catch: automatic "reaper" jobs that stop or delete instances after some hours,
and per-tag cost policies. Ask the account administrator about both.
