```md
# envs module (EKS + Aurora PG Serverless v2)

Inputs come from the root `instances.tf` map. The module creates:
- EKS cluster + one managed node group
- Secrets Manager secret for DB master creds
- Aurora PostgreSQL Serverless v2 (one instance class `db.serverless`)
- DB SG that only allows port 5432 from the EKS node group SG

> Exposing services: install the AWS Load Balancer Controller and define Ingress resources; optionally external-dns and cert-manager.