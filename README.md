# Finance Control - Infrastructure

Infraestrutura local completa do Finance Control com Docker Compose.

Também existe um alvo de hospedagem própria para ZimaOS, preservando os
containers atuais, os bancos independentes no Neon e o isolamento de acesso pelo
BFF.

A implantação pública atual usa Vercel para o Angular, zrok para o túnel até o
ZimaOS e três bancos PostgreSQL independentes no Neon. Os arquivos de OCI e
Cloudflare permanecem como uma alternativa histórica não ativa. O ambiente
local descrito abaixo permanece inalterado.

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

As requisições recebem o header `X-Correlation-ID`, preservado pelo BFF nas
chamadas aos dois serviços. Para localizar uma operação completa nos logs JSON,
copie o UUID retornado pela API e execute:

```powershell
docker compose logs bff finance-service debt-service | Select-String "UUID_AQUI"
```

Os logs registram método, caminho, status e duração, mas não incluem payloads,
tokens ou parâmetros de consulta.

## Integração contínua

O workflow `.github/workflows/ci.yml` é executado em pushes e pull requests para
`main` e `develop`, além de permitir execução manual com referências específicas
dos demais repositórios. A pipeline valida o Compose, constrói e sobe o stack
completo, verifica os endpoints `/health` do Frontend e do BFF e executa a suíte
Playwright contra os containers e bancos descartáveis.

Os cenários automatizados cobrem autenticação e restauração de sessão, receitas,
despesas, categorias personalizadas, orçamento, metas, recorrências, dashboard,
análise e perguntas à IA mock, amizades, grupos, edição de dívida e pagamento
simplificado entre duas contas. Em caso de falha, o GitHub Actions publica por
sete dias o relatório HTML, traces, screenshots e vídeos do Playwright, além dos
logs do Docker Compose. Ao final, containers e volumes temporários são removidos.

Para executar a mesma suíte completa localmente a partir do frontend:

```powershell
cd ..\finance-control-frontend
npm ci --ignore-scripts
npm exec playwright install chromium
npm run test:e2e:isolated
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

O Finance Service usa seu PostgreSQL e controla o schema com Flyway. Debt Service e BFF usam bancos PostgreSQL independentes e migrations do Entity Framework Core. O BFF persiste Identity, sessões, notificações e chaves Data Protection no próprio banco exclusivo, portanto links de segurança continuam válidos depois de reiniciar ou recriar o container.

## Análise inteligente

O ambiente local inicia com `AI_PROVIDER=Mock`, produzindo respostas determinísticas sem chave ou container adicional.

Para ativar um provedor real, copie `.env.example` para `.env` e ajuste apenas as variáveis `AI_*`. Exemplo com o free tier do Groq:

```text
AI_PROVIDER=OpenAiCompatible
AI_BASE_URL=https://api.groq.com/openai/v1/
AI_API_KEY=sua-chave-groq
AI_MODEL=openai/gpt-oss-20b
```

Depois, reconstrua somente o BFF:

```powershell
docker compose up --detach --build --wait bff
```

Como alternativa de testes, use `https://openrouter.ai/api/v1/` e o modelo `openrouter/free`. A integração permanece restrita ao BFF; frontend e microserviços nunca acessam o provedor diretamente. Não versione o arquivo `.env` nem uma chave real.

## Staging gratuito na OCI

Os artefatos de staging são separados do Compose local:

| Caminho | Responsabilidade |
|---|---|
| `compose.oci.yml` | Caddy, BFF, Finance e Debt usando imagens multiarch |
| `.env.oci.example` | contrato completo de configuração sem secrets reais |
| `deploy/oci/Caddyfile` | TLS, SignalR e proteção da origem por header secreto |
| `terraform/oci` | VCN, firewall, subnet e VM A1 Always Free |

Para o TLS sem comprar domínio, registre um subdomínio gratuito no DuckDNS,
aponte-o ao output `public_ipv4` do Terraform e use o hostname em
`BFF_PUBLIC_HOST`. O token do DuckDNS não precisa entrar na VM nem no Terraform;
atualize o endereço manualmente apenas se a VM for recriada com outro IP.

Os bancos não são containers nesse ambiente. Cada serviço recebe somente a
conexão TLS do próprio projeto Neon. Para validar o Compose sem revelar secrets,
copie o exemplo para um arquivo ignorado e substitua os placeholders:

```bash
cp .env.oci.example .env.oci
chmod 600 .env.oci
docker compose --env-file .env.oci -f compose.oci.yml config --quiet
docker compose --env-file .env.oci -f compose.oci.yml up --detach --wait
```

### Projetos Neon

O staging usa três projetos independentes no plano Free, todos em AWS South
America East 1 (São Paulo), com PostgreSQL 17:

| Projeto | Banco | Consumidor exclusivo |
|---|---|---|
| `finance-control-bff` | `finance_control_bff` | BFF |
| `finance-control-finance-service` | `finance_control_finance` | Finance Service |
| `finance-control-debt-service` | `finance_control_debt` | Debt Service |

No painel de cada projeto, abra **Connect**, selecione o banco indicado e deixe
**Pooled connection** desativado. Use a connection string direta porque BFF,
Debt e Finance executam migrations na inicialização. Para BFF e Debt, converta
os campos para o formato Npgsql mostrado em `.env.oci.example`. Para Finance,
selecione Java/JDBC no painel e separe URL, usuário e senha nas três variáveis
`FINANCE_DATABASE_*`.

O arquivo `.env.oci` é ignorado pelo Git e deve ter permissão `600` na VM. Não
use a conexão de um projeto em outro serviço. O plano Free fornece atualmente,
por projeto, 100 CU-h mensais, 0,5 GB de armazenamento e 5 GB de transferência,
com scale-to-zero após inatividade; acompanhe esses medidores no dashboard Neon.

Somente o Caddy publica portas. BFF, Finance e Debt não possuem `ports` e se
comunicam por nomes internos do Compose. No alvo OCI legado, o
`ORIGIN_VERIFY_TOKEN` deve ser igual ao secret configurado no Cloudflare Pages
Worker. A implantação atual no ZimaOS não utiliza esse token.

## Hospedagem própria no ZimaOS

O arquivo `compose.zimaos.yml` executa Caddy, BFF, Finance Service e Debt Service
sem publicar nenhuma porta do host. O profile opcional `public` acrescenta o
agente zrok 2.0.4. Finance e Debt permanecem acessíveis apenas pelas redes do
Compose; o túnel alcança somente o Caddy pela rede Docker privada e o Caddy
encaminha as requisições ao BFF. Nenhuma porta do roteador, do host ou da WebUI
do ZimaOS é publicada.

Os limites atuais foram definidos para um host x86-64 com 4 cores/8 threads e
16 GB de RAM que também executa um servidor Minecraft:

| Serviço | Memória máxima | CPU máxima |
|---|---:|---:|
| Caddy | 128 MB | 0,10 |
| zrok Agent | 256 MB | 0,25 |
| BFF | 768 MB | 0,50 |
| Finance Service | 1,5 GB | 0,75 |
| Debt Service | 768 MB | 0,50 |

Antes da instalação, crie um arquivo ignorado com os valores reais. O contrato
é compatível com os secrets já usados pelo staging OCI:

```bash
cp .env.zimaos.example .env.zimaos
chmod 600 .env.zimaos
docker compose --env-file .env.zimaos -f compose.zimaos.yml config --quiet
```

Para iniciar os backends e validar os health checks sem exposição pública:

```bash
docker compose --env-file .env.zimaos -f compose.zimaos.yml up --detach --wait
```

Crie uma conta gratuita em `myzrok.io`, copie o account token para
`ZROK2_ENABLE_TOKEN` e escolha um nome em `ZROK2_SHARE_NAME`. O token fica
somente no arquivo ignorado com permissão `600`. Para habilitar o ambiente,
reservar o nome e iniciar o compartilhamento persistente:

```powershell
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action SyncEnvironment
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action InitializePublicTunnel
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action PublicStatus
```

O helper cria uma share pública nomeada para `http://edge:8080`. Shares nomeadas
são restauradas automaticamente pelo agente após reinícios. O volume
`finance-control-zrok-environment` persiste somente a identidade do dispositivo
e nunca deve ser removido em uma atualização comum. Não publique o console do
agente, a WebUI do ZimaOS, BFF, Finance ou Debt e não abra portas no roteador.

As imagens referenciadas em `.env.oci` são publicadas pelos workflows dos três
repositórios de backend. Após a primeira publicação, confirme no GitHub que cada
package GHCR está com visibilidade `Public`; assim a VM pode baixar as imagens
sem armazenar um token do GitHub.

### Deploy automático no ZimaOS

Os workflows de BFF, Finance e Debt publicam duas referências após cada merge
protegido na `develop`: a tag móvel `develop` e a tag imutável
`sha-<commit>`. Tags de release `v*` continuam publicando a versão sem o prefixo
`v`. O ZimaOS usa somente as tags `develop` no ambiente de portfólio; ambientes
de release podem continuar fixando versão e digest.

O timer `finance-control-auto-update.timer` verifica as três imagens a cada
cinco minutos. A rotina possui lock contra execuções concorrentes, não reinicia
containers quando os digests não mudaram, aguarda os health checks do Compose e
valida o Caddy. Antes da atualização, mantém tags locais das imagens em execução.
Se algum health check falhar, restaura as três imagens anteriores e coloca a
combinação defeituosa em quarentena até que um novo digest seja publicado.

Instale ou atualize a automação sem abrir portas e sem armazenar credenciais do
GitHub no servidor:

```powershell
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action InstallAutoDeploy
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action AutoDeployStatus
```

Para disparar uma verificação imediata ou consultar os logs do `systemd`:

```powershell
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action RunAutoDeploy
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action AutoDeployLogs -Tail 100
```

Não existe webhook, runner self-hosted ou endpoint administrativo público. O
servidor inicia somente conexões de saída para o GHCR, e apenas imagens geradas
após merge na branch protegida podem atualizar as tags acompanhadas.

### Acesso operacional seguro ao ZimaOS

As credenciais administrativas não ficam no repositório. O inicializador cria
`%USERPROFILE%\.finance-control`, restringe sua ACL ao usuário atual e ao
`SYSTEM`, gera uma chave SSH Ed25519 e armazena a senha sudo com DPAPI. O XML
criptografado só pode ser aberto pelo mesmo usuário no mesmo computador.

Primeiro gere a chave e o arquivo de configuração, sem solicitar a senha:

```powershell
pwsh -File .\tools\Initialize-ZimaOsAccess.ps1 -SkipCredential
```

Autorize o conteúdo da chave pública indicada pelo comando no usuário do
ZimaOS. Depois armazene a credencial sudo; a senha é solicitada de forma
interativa e nunca é gravada em texto puro:

```powershell
pwsh -File .\tools\Initialize-ZimaOsAccess.ps1
```

O helper aceita somente operações predefinidas e não recebe comandos remotos
arbitrários:

```powershell
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action Status
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action Health
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action Logs -Service bff -Tail 200
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action SyncEnvironment
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action Deploy
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action Restart
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action InitializePublicTunnel
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action PublicStatus
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action InstallAutoDeploy
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action AutoDeployStatus
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action RunAutoDeploy
pwsh -File .\tools\Invoke-ZimaOsFinanceControl.ps1 -Action AutoDeployLogs -Tail 100
```

`SyncEnvironment` transfere o `.env.oci` ignorado pelo Git por SSH, valida o
Compose no servidor antes da substituição, instala o arquivo com permissão
`600`, remove o upload temporário e recria somente BFF e Caddy.

A chave privada, o arquivo DPAPI e o `known_hosts` permanecem fora de todos os
repositórios. Não copie o cofre para outro computador: a criptografia não será
decifrável fora da conta Windows que o criou.
