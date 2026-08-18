# OCI Always Free com Terraform

Este módulo cria somente a rede e uma VM ARM64 destinada ao staging. A
configuração fixa a shape em `VM.Standard.A1.Flex`, 2 OCPUs, 12 GB de RAM e
boot volume de 50 GB. Não existe fallback para recursos pagos.

## Pré-requisitos

- conta OCI ainda no modo Free Tier;
- compartment exclusivo para staging;
- Terraform CLI `1.13.3`;
- provider `oracle/oci` `8.25.0`;
- autenticação OCI configurada localmente ou execução pelo Resource Manager;
- chave SSH Ed25519 exclusiva;
- imagem Ubuntu 24.04 ARM64 marcada como Always Free-eligible.

Copie `terraform.tfvars.example` para `terraform.tfvars`, preencha os OCIDs e
execute:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan
```

Antes de `terraform apply`, confirme no plano:

- exatamente uma `VM.Standard.A1.Flex`;
- exatamente 2 OCPUs e 12 GB;
- boot volume de 50 GB;
- nenhuma Load Balancer, NAT Gateway, database ou shape adicional;
- SSH restrito ao seu endereço `/32`.

Depois da criação, use o output `public_ipv4` no hostname gratuito e copie para
`/opt/finance-control` apenas `compose.oci.yml`, `deploy/oci/Caddyfile` e um
`.env.oci` real com permissão `0600`.

O hostname recomendado é um subdomínio DuckDNS gratuito. Atualize-o manualmente
com o `public_ipv4`; o token do provedor DNS fica fora do Terraform e da VM.
