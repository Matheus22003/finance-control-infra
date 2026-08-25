# Changelog

## [Unreleased]

### Added

- Beszel e Uptime Kuma locais, isolados do túnel público e com imagens fixadas;
- backup semanal dos três PostgreSQL e quatro volumes operacionais do ZimaOS;
- ensaio automático de restauração em PostgreSQL e volumes descartáveis;
- helpers restritos para operação, saúde, backup, restauração e observabilidade;
- Compose de staging para OCI ARM64 sem bancos locais;
- Caddy com TLS, WebSocket e validação do origin secret do Cloudflare Worker;
- contrato de variáveis para três PostgreSQL Neon, Brevo e Groq;
- Terraform `1.13.3` com provider OCI `8.25.0` para uma VM Always Free;
- cloud-init com Docker, Compose e usuário de deploy endurecido.

## [0.1.0] - 2026-08-13

### Added

- stack Docker Compose com Frontend, BFF, Finance, Debt e Mailpit;
- três PostgreSQL independentes e redes de dados isoladas por serviço;
- health checks, volumes persistentes e variáveis locais documentadas;
- provider de IA configurável com Mock como padrão seguro;
- propagação de configuração para correlação, e-mail e rate limiting;
- CI integrado que constrói o stack e executa 11 cenários Playwright;
- publicação de relatórios, traces, vídeos, screenshots e logs em falhas.

[Unreleased]: https://github.com/Matheus22003/finance-control-infra/compare/v0.1.0...develop
[0.1.0]: https://github.com/Matheus22003/finance-control-infra/releases/tag/v0.1.0
