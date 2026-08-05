# Finance Control - Infrastructure

Infraestrutura local completa do Finance Control com Docker Compose.

## Serviços

| Serviço | Porta publicada | Acesso |
|---|---:|---|
| Frontend Angular | `4200` | Navegador |
| BFF | `8080` | Host e proxy interno do frontend |
| Finance Service | nenhuma | Somente rede interna de serviços |
| Debt Service | nenhuma | Somente rede interna de serviços |
| Mailpit | `8025` | Caixa de e-mail local; SMTP interno na porta `1025` |
| BFF PostgreSQL | nenhuma | Somente BFF |
| Finance PostgreSQL | nenhuma | Somente Finance Service |
| Debt PostgreSQL | nenhuma | Somente Debt Service |

É usado PostgreSQL `17.10` sobre Alpine `3.23`, com a imagem fixada também por digest.

## Isolamento de rede

- `edge-network`: comunicação Frontend → BFF.
- `services-network`: comunicação BFF → Finance/Debt.
- `bff-data-network`: comunicação exclusiva BFF → BFF PostgreSQL.
- `finance-data-network`: comunicação exclusiva Finance → Finance PostgreSQL.
- `debt-data-network`: comunicação exclusiva Debt → Debt PostgreSQL.

Nenhum serviço consegue acessar diretamente o banco de outro domínio. O frontend não participa das redes dos microserviços ou bancos.

## Configuração inicial

Crie o arquivo local de variáveis a partir do exemplo:

```powershell
Copy-Item .env.example .env
```

As credenciais presentes em `.env.example` são exclusivamente para desenvolvimento local. O arquivo `.env` é ignorado pelo Git.

## Subir o ambiente

Os repositórios abaixo precisam estar lado a lado na mesma pasta:

```text
finance-control-frontend/
finance-control-bff/
finance-control-finance-service/
finance-control-debt-service/
finance-control-infra/
```

Execute dentro de `finance-control-infra`:

```powershell
docker compose config --quiet
docker compose up --build --detach --wait
```

Acesse:

- Aplicação: `http://localhost:4200`
- Health do frontend: `http://localhost:4200/health`
- Health do BFF: `http://localhost:8080/health`
- E-mails locais (Mailpit): `http://localhost:8025`

Credenciais demonstrativas:

```text
email: demo@financecontrol.local
senha: ChangeMe123!
```

## Estado e logs

```powershell
docker compose ps
docker compose logs --follow
docker compose logs --follow frontend bff finance-service debt-service
```

## Parar o ambiente

Preserva os dados PostgreSQL:

```powershell
docker compose down
```

Remove também os três volumes de banco. Use somente quando quiser apagar todos os dados locais:

```powershell
docker compose down --volumes
```

## Bancos e migrations

O Finance Service usa seu PostgreSQL e controla o schema com Flyway. Debt Service e BFF usam bancos PostgreSQL independentes e migrations do Entity Framework Core. O BFF persiste Identity, sessões e notificações. As chaves que protegem os links de e-mail ficam em um volume dedicado, portanto continuam válidas depois de reiniciar o container.

## Análise inteligente

O ambiente local inicia com `AI_PROVIDER=Mock`, produzindo respostas determinísticas sem chave ou container adicional.

Para ativar um provedor real, copie `.env.example` para `.env` e ajuste apenas as variáveis `AI_*`. Exemplo com o free tier do Groq:

```text
AI_PROVIDER=OpenAiCompatible
AI_BASE_URL=https://api.groq.com/openai/v1/
AI_API_KEY=sua-chave-groq
AI_MODEL=llama-3.1-8b-instant
```

Depois, reconstrua somente o BFF:

```powershell
docker compose up --detach --build --wait bff
```

Como alternativa de testes, use `https://openrouter.ai/api/v1/` e o modelo `openrouter/free`. A integração permanece restrita ao BFF; frontend e microserviços nunca acessam o provedor diretamente. Não versione o arquivo `.env` nem uma chave real.
