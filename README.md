# mtga-companion-infra

Infrastructure as Code for MTGA Companion — CloudFormation templates, EC2/RDS setup, nginx config, and deployment scripts.

## Structure

```
cloudformation/   — AWS CloudFormation templates (VPC, RDS, EC2, DNS)
scripts/          — Bootstrap and deploy scripts
nginx/            — nginx site configuration
systemd/          — systemd service definitions
```

## AWS Account

Account: 901347789205 — always use `AWS_PROFILE=personal`

## Deployment Order

Run stacks in this order — each depends on the previous:

1. `vpc.yml` — VPC, subnets, security groups *(not yet written)*
2. `rds.yml` — RDS PostgreSQL db.t3.micro ✅
3. `ec2.yml` — EC2 t3.small *(not yet written)*
4. `dns.yml` — Route 53 records *(after domain purchase)*

**Hold all deployments until AWS Activate credits are confirmed.**

## Status

- [ ] VPC + security groups (`cloudformation/vpc.yml`)
- [x] RDS PostgreSQL db.t3.micro (`cloudformation/rds.yml`) — pgvector-enabled, private subnet only
- [ ] EC2 t3.small (`cloudformation/ec2.yml`)
- [ ] nginx + SSL (`nginx/mtga-companion.conf`)
- [ ] systemd service (`systemd/mtga-companion.service`)
- [ ] GitHub Actions deploy step
