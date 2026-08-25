#!/bin/sh

set -eu

umask 077
export LC_ALL=C

ACTION="${1:-create}"
PROJECT_DIRECTORY="${FINANCE_CONTROL_DIRECTORY:-/DATA/AppData/finance-control}"
BACKUP_ROOT="${FINANCE_CONTROL_BACKUP_ROOT:-$PROJECT_DIRECTORY/backups}"
RETENTION_COUNT="${FINANCE_CONTROL_BACKUP_RETENTION:-7}"
POSTGRES_IMAGE='postgres:17.10-alpine3.23@sha256:8189a1f6e40904781fc9e2612687877791d21679866db58b1de996b31fc312e4'
BUSYBOX_IMAGE='docker.io/library/busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0'

running_observability=''
verify_container=''
verify_volumes=''
current_backup_directory=''

app_compose() {
  docker compose --env-file "$PROJECT_DIRECTORY/.env.zimaos" \
    -f "$PROJECT_DIRECTORY/compose.zimaos.yml" "$@"
}

observability_compose() {
  docker compose --env-file "$PROJECT_DIRECTORY/.env.observability" \
    --env-file "$PROJECT_DIRECTORY/.env.observability.runtime" \
    -f "$PROJECT_DIRECTORY/compose.observability.yml" "$@"
}

cleanup() {
  if [ -n "$verify_container" ]; then
    docker rm --force --volumes "$verify_container" >/dev/null 2>&1 || true
    verify_container=''
  fi

  for volume in $verify_volumes; do
    docker volume rm --force "$volume" >/dev/null 2>&1 || true
  done
  verify_volumes=''

  if [ -n "$running_observability" ]; then
    observability_compose --profile agent up --detach --wait $running_observability >/dev/null
    running_observability=''
  fi

  if [ -n "$current_backup_directory" ] && [ ! -f "$current_backup_directory/COMPLETE" ]; then
    rm -rf -- "$current_backup_directory"
  fi
}

trap cleanup EXIT HUP INT TERM

require_file() {
  local required_path="$1"
  if [ ! -s "$required_path" ]; then
    printf 'Arquivo obrigatório ausente ou vazio: %s\n' "$required_path" >&2
    exit 1
  fi
}

read_service_environment() {
  local service="$1"
  local variable="$2"
  local container_id
  container_id="$(app_compose ps --quiet "$service")"
  if [ -z "$container_id" ]; then
    printf 'Serviço não está em execução: %s\n' "$service" >&2
    exit 1
  fi

  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" |
    awk -v prefix="$variable=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }'
}

read_connection_field() {
  local connection_string="$1"
  local field="$2"
  printf '%s' "$connection_string" |
    awk -v target="$field" '
      BEGIN { RS = ";" }
      {
        separator = index($0, "=")
        if (separator == 0) next
        key = substr($0, 1, separator - 1)
        value = substr($0, separator + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (tolower(key) == tolower(target)) {
          first = substr(value, 1, 1)
          last = substr(value, length(value), 1)
          if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
            value = substr(value, 2, length(value) - 2)
          }
          gsub(/\"\"/, "\"", value)
          print value
          exit
        }
      }
    '
}

require_value() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    printf 'Não foi possível obter o campo obrigatório: %s\n' "$name" >&2
    exit 1
  fi
}

dump_database() {
  local dump_directory="$1"
  local backup_name="$2"
  local host="$3"
  local port="$4"
  local database="$5"
  local username="$6"
  local password="$7"

  docker run --rm \
    --user 0:0 \
    --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,size=64m \
    --env PGPASSWORD="$password" \
    --volume "$dump_directory:/backup" \
    "$POSTGRES_IMAGE" \
    pg_dump \
      --host "$host" \
      --port "$port" \
      --username "$username" \
      --dbname "$database" \
      --format custom \
      --compress 9 \
      --no-owner \
      --no-acl \
      --file "/backup/$backup_name.dump"
}

archive_volume() {
  local archive_directory="$1"
  local volume_name="$2"
  local archive_name="$3"

  docker volume inspect "$volume_name" >/dev/null
  docker run --rm \
    --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,size=16m \
    --volume "$volume_name:/source:ro" \
    --volume "$archive_directory:/backup" \
    "$BUSYBOX_IMAGE" \
    tar -czf "/backup/$archive_name.tar.gz" -C /source .
}

pause_observability() {
  local service
  local container_id
  for service in beszel-hub beszel-agent uptime-kuma; do
    container_id="$(observability_compose --profile agent ps --quiet "$service")"
    if [ -n "$container_id" ] && [ "$(docker inspect --format '{{.State.Running}}' "$container_id")" = 'true' ]; then
      running_observability="$running_observability $service"
    fi
  done

  if [ -n "$running_observability" ]; then
    observability_compose --profile agent stop $running_observability >/dev/null
  fi
}

resume_observability() {
  if [ -n "$running_observability" ]; then
    observability_compose --profile agent up --detach --wait $running_observability >/dev/null
    running_observability=''
  fi
}

verify_database_backups() {
  local verify_backup_directory="$1"
  local verify_password='finance-control-restore-verification-only'
  local attempts
  local database
  local table_count
  verify_container="finance-control-backup-verify-$$"

  docker run --detach \
    --name "$verify_container" \
    --env POSTGRES_PASSWORD="$verify_password" \
    --tmpfs /var/lib/postgresql/data:rw,nosuid,nodev,size=1024m \
    --volume "$verify_backup_directory/databases:/backup:ro" \
    "$POSTGRES_IMAGE" >/dev/null

  attempts=0
  until docker exec "$verify_container" pg_isready --username postgres >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      printf 'PostgreSQL temporário não ficou pronto para o ensaio de restauração.\n' >&2
      exit 1
    fi
    sleep 1
  done

  for database in bff finance debt; do
    docker exec --env PGPASSWORD="$verify_password" "$verify_container" \
      createdb --username postgres "verify_$database"
    docker exec --env PGPASSWORD="$verify_password" "$verify_container" \
      pg_restore \
        --exit-on-error \
        --no-owner \
        --no-acl \
        --username postgres \
        --dbname "verify_$database" \
        "/backup/$database.dump"
    table_count="$(docker exec --env PGPASSWORD="$verify_password" "$verify_container" \
      psql --tuples-only --no-align --username postgres --dbname "verify_$database" \
      --command "select count(*) from information_schema.tables where table_schema = 'public';")"
    if [ "${table_count:-0}" -le 0 ]; then
      printf 'A restauração de %s não produziu tabelas públicas.\n' "$database" >&2
      exit 1
    fi
  done

  docker rm --force --volumes "$verify_container" >/dev/null
  verify_container=''
}

verify_volume_backups() {
  local verify_backup_directory="$1"
  local archive_path
  local archive_name
  local safe_name
  local restore_volume

  for archive_path in "$verify_backup_directory"/volumes/*.tar.gz; do
    archive_name="$(basename "$archive_path")"
    safe_name="$(printf '%s' "$archive_name" | tr -c 'a-zA-Z0-9' '-')"
    restore_volume="finance-control-restore-verify-$$-$safe_name"
    verify_volumes="$verify_volumes $restore_volume"
    docker volume create "$restore_volume" >/dev/null
    docker run --rm \
      --read-only \
      --tmpfs /tmp:rw,nosuid,nodev,size=16m \
      --volume "$verify_backup_directory/volumes:/backup:ro" \
      --volume "$restore_volume:/restore" \
      "$BUSYBOX_IMAGE" \
      sh -eu -c 'tar -xzf "/backup/$1" -C /restore; test -n "$(find /restore -mindepth 1 -print -quit)"' \
      sh "$archive_name"
    docker volume rm "$restore_volume" >/dev/null
    verify_volumes="$(printf '%s' "$verify_volumes" | sed "s| $restore_volume||")"
  done
}

verify_backup() {
  local verify_backup_directory="$1"
  require_file "$verify_backup_directory/SHA256SUMS"
  require_file "$verify_backup_directory/MANIFEST"

  (
    cd "$verify_backup_directory"
    sha256sum --check SHA256SUMS
  )
  verify_database_backups "$verify_backup_directory"
  verify_volume_backups "$verify_backup_directory"
  touch "$verify_backup_directory/VERIFIED"
  chmod 600 "$verify_backup_directory/VERIFIED"
  printf 'restore_verification=ok\n'
}

create_backup() {
  local timestamp
  local backup_directory
  local database_directory
  local volume_directory
  local bff_connection bff_host bff_port bff_database bff_username bff_password
  local debt_connection debt_host debt_port debt_database debt_username debt_password
  local finance_jdbc finance_username finance_password finance_location finance_authority
  local finance_path finance_database finance_host finance_port required expired
  require_file "$PROJECT_DIRECTORY/.env.zimaos"
  require_file "$PROJECT_DIRECTORY/.env.observability"
  require_file "$PROJECT_DIRECTORY/.env.observability.runtime"

  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z' |
    while IFS= read -r incomplete; do
      if [ ! -f "$incomplete/COMPLETE" ]; then
        rm -rf -- "$incomplete"
      fi
    done

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_directory="$BACKUP_ROOT/$timestamp"
  current_backup_directory="$backup_directory"
  database_directory="$backup_directory/databases"
  volume_directory="$backup_directory/volumes"
  mkdir -p "$database_directory" "$volume_directory"
  chmod 700 "$BACKUP_ROOT" "$backup_directory" "$database_directory" "$volume_directory"

  bff_connection="$(read_service_environment bff ConnectionStrings__BffDatabase)"
  bff_host="$(read_connection_field "$bff_connection" Host)"
  bff_port="$(read_connection_field "$bff_connection" Port)"
  bff_database="$(read_connection_field "$bff_connection" Database)"
  bff_username="$(read_connection_field "$bff_connection" Username)"
  bff_password="$(read_connection_field "$bff_connection" Password)"

  debt_connection="$(read_service_environment debt-service ConnectionStrings__DebtDatabase)"
  debt_host="$(read_connection_field "$debt_connection" Host)"
  debt_port="$(read_connection_field "$debt_connection" Port)"
  debt_database="$(read_connection_field "$debt_connection" Database)"
  debt_username="$(read_connection_field "$debt_connection" Username)"
  debt_password="$(read_connection_field "$debt_connection" Password)"

  finance_jdbc="$(read_service_environment finance-service SPRING_DATASOURCE_URL)"
  finance_username="$(read_service_environment finance-service SPRING_DATASOURCE_USERNAME)"
  finance_password="$(read_service_environment finance-service SPRING_DATASOURCE_PASSWORD)"
  finance_location="${finance_jdbc#jdbc:postgresql://}"
  finance_authority="${finance_location%%/*}"
  finance_path="${finance_location#*/}"
  finance_database="${finance_path%%\?*}"
  case "$finance_authority" in
    *:*)
      finance_host="${finance_authority%%:*}"
      finance_port="${finance_authority##*:}"
      ;;
    *)
      finance_host="$finance_authority"
      finance_port='5432'
      ;;
  esac

  for required in \
    "bff_host:$bff_host" "bff_port:$bff_port" "bff_database:$bff_database" \
    "bff_username:$bff_username" "bff_password:$bff_password" \
    "debt_host:$debt_host" "debt_port:$debt_port" "debt_database:$debt_database" \
    "debt_username:$debt_username" "debt_password:$debt_password" \
    "finance_host:$finance_host" "finance_port:$finance_port" \
    "finance_database:$finance_database" "finance_username:$finance_username" \
    "finance_password:$finance_password"; do
    require_value "${required%%:*}" "${required#*:}"
  done

  dump_database "$database_directory" bff "$bff_host" "$bff_port" "$bff_database" "$bff_username" "$bff_password"
  dump_database "$database_directory" finance "$finance_host" "$finance_port" "$finance_database" "$finance_username" "$finance_password"
  dump_database "$database_directory" debt "$debt_host" "$debt_port" "$debt_database" "$debt_username" "$debt_password"

  unset bff_connection bff_password debt_connection debt_password finance_password

  pause_observability
  archive_volume "$volume_directory" finance-control-zrok-environment zrok-environment
  archive_volume "$volume_directory" finance-control-beszel-data beszel-data
  archive_volume "$volume_directory" finance-control-beszel-agent-data beszel-agent-data
  archive_volume "$volume_directory" finance-control-uptime-kuma-data uptime-kuma-data
  resume_observability

  cat >"$backup_directory/MANIFEST" <<EOF
format_version=1
created_at_utc=$timestamp
database_format=postgresql_custom
database_count=3
volume_count=4
retention_count=$RETENTION_COUNT
EOF
  (
    cd "$backup_directory"
    sha256sum databases/*.dump volumes/*.tar.gz >SHA256SUMS
  )
  chmod 600 "$backup_directory/MANIFEST" "$backup_directory/SHA256SUMS" \
    "$database_directory"/*.dump "$volume_directory"/*.tar.gz

  verify_backup "$backup_directory"
  touch "$backup_directory/COMPLETE"
  chmod 600 "$backup_directory/COMPLETE"
  ln -sfn "$timestamp" "$BACKUP_ROOT/latest"

  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z' \
    -printf '%f\n' | sort -r | awk -v keep="$RETENTION_COUNT" 'NR > keep' |
    while IFS= read -r expired; do
      rm -rf -- "$BACKUP_ROOT/$expired"
    done

  printf 'backup_created=%s\n' "$timestamp"
  current_backup_directory=''
}

latest_backup_directory() {
  if [ ! -L "$BACKUP_ROOT/latest" ]; then
    printf 'Nenhum backup foi criado ainda.\n' >&2
    exit 1
  fi
  readlink -f "$BACKUP_ROOT/latest"
}

show_status() {
  local backup_directory
  backup_directory="$(latest_backup_directory)"
  printf 'latest_backup=%s\n' "$(basename "$backup_directory")"
  if [ -f "$backup_directory/VERIFIED" ]; then
    printf 'latest_restore_verification=ok\n'
  else
    printf 'latest_restore_verification=pending\n'
  fi
  printf 'latest_backup_size_bytes=%s\n' "$(du -sb "$backup_directory" | awk '{print $1}')"
  printf 'retained_backups=%s\n' "$(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type f -name COMPLETE | wc -l | tr -d ' ')"
}

case "$ACTION" in
  create)
    create_backup
    ;;
  verify)
    verify_backup "$(latest_backup_directory)"
    ;;
  status)
    show_status
    ;;
  *)
    printf 'Ação inválida: %s. Use create, verify ou status.\n' "$ACTION" >&2
    exit 1
    ;;
esac
