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

## Status

- [ ] VPC + security groups
- [ ] RDS PostgreSQL (db.t3.micro)
- [ ] EC2 t3.small
- [ ] nginx + SSL
- [ ] systemd service
- [ ] GitHub Actions deploy step
