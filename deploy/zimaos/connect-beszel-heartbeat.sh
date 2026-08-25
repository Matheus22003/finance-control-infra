#!/bin/sh

set -eu

compose='docker compose --env-file .env.observability --env-file .env.observability.runtime -f compose.observability.yml'
runtime_environment='.env.observability.runtime'
temporary_environment="$(mktemp .env.observability.runtime.XXXXXX)"

cleanup() {
  rm -f "$temporary_environment"
}

trap cleanup EXIT HUP INT TERM

push_token="$($compose exec -T uptime-kuma node - <<'NODE'
const sqlite3 = require("@louislam/sqlite3").verbose();
const database = new sqlite3.Database(
    "/app/data/kuma.db",
    sqlite3.OPEN_READONLY,
    (openError) => {
        if (openError) {
            console.error("Não foi possível abrir o banco do Uptime Kuma.");
            process.exitCode = 1;
        }
    },
);

database.all(
    "SELECT push_token FROM monitor WHERE type = 'push' ORDER BY id",
    (queryError, rows) => {
        if (queryError || rows.length !== 1 || !rows[0].push_token) {
            console.error("Mantenha exatamente um monitor Push antes de conectar o Beszel.");
            process.exitCode = 1;
        } else {
            process.stdout.write(rows[0].push_token);
        }

        database.close();
    },
);
NODE
)"

if [ -z "$push_token" ]; then
  echo 'O token Push do Uptime Kuma não foi encontrado.' >&2
  exit 1
fi

umask 077
printf '%s\n' \
  "BESZEL_HEARTBEAT_URL=http://uptime-kuma:3001/api/push/${push_token}?status=up&msg=OK&ping=" \
  >"$temporary_environment"
install -o root -g root -m 600 "$temporary_environment" "$runtime_environment"

$compose up --detach --wait --no-deps beszel-hub
printf 'beszel_heartbeat_connected=true\n'
