#!/bin/sh

set -eu

app_directory="${FINANCE_CONTROL_APP_DIR:-/DATA/AppData/finance-control}"
environment_file="${app_directory}/.env.zimaos"
compose_file="${app_directory}/compose.zimaos.yml"
state_directory="${app_directory}/.auto-update"
lock_file="${state_directory}/update.lock"
failed_candidate_file="${state_directory}/failed-candidate"
last_successful_file="${state_directory}/last-successful"
run_id="$(date -u +%Y%m%d%H%M%S)"

rollback_bff=""
rollback_finance=""
rollback_debt=""

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

compose() {
    docker compose --env-file "$environment_file" -f "$compose_file" "$@"
}

read_environment_value() {
    key="$1"
    sed -n "s/^${key}=//p" "$environment_file" | tail -n 1
}

container_image_id() {
    service="$1"
    container_id="$(compose ps -q "$service")"
    if [ -z "$container_id" ]; then
        log "service=${service} status=container-missing"
        return 1
    fi
    docker inspect --format '{{.Image}}' "$container_id"
}

image_id() {
    reference="$1"
    docker image inspect --format '{{.Id}}' "$reference"
}

fingerprint() {
    printf '%s\n%s\n%s\n' "$1" "$2" "$3" | sha256sum | awk '{print $1}'
}

# Invoked indirectly by the EXIT trap registered before pulling candidate images.
# shellcheck disable=SC2329
cleanup_rollback_tags() {
    for reference in "$rollback_bff" "$rollback_finance" "$rollback_debt"; do
        if [ -n "$reference" ]; then
            docker image rm "$reference" >/dev/null 2>&1 || true
        fi
    done
}

rollback() {
    log 'deployment=rollback status=starting'
    export BFF_IMAGE="$rollback_bff"
    export FINANCE_IMAGE="$rollback_finance"
    export DEBT_IMAGE="$rollback_debt"

    if compose up --detach --wait --wait-timeout 240 finance-service debt-service bff; then
        log 'deployment=rollback status=healthy'
        return 0
    fi

    log 'deployment=rollback status=failed'
    return 1
}

mkdir -p "$state_directory"
chmod 700 "$state_directory"

exec 9>"$lock_file"
if ! flock -n 9; then
    log 'deployment=skipped reason=already-running'
    exit 0
fi

if [ ! -s "$environment_file" ] || [ ! -s "$compose_file" ]; then
    log 'deployment=failed reason=configuration-missing'
    exit 1
fi

compose config --quiet

old_bff_id="$(container_image_id bff)"
old_finance_id="$(container_image_id finance-service)"
old_debt_id="$(container_image_id debt-service)"
current_fingerprint="$(fingerprint "$old_bff_id" "$old_finance_id" "$old_debt_id")"

rollback_bff="finance-control-rollback-bff:${run_id}"
rollback_finance="finance-control-rollback-finance:${run_id}"
rollback_debt="finance-control-rollback-debt:${run_id}"
docker image tag "$old_bff_id" "$rollback_bff"
docker image tag "$old_finance_id" "$rollback_finance"
docker image tag "$old_debt_id" "$rollback_debt"
trap cleanup_rollback_tags EXIT

log 'deployment=pull status=starting'
if ! compose pull --quiet bff finance-service debt-service; then
    log 'deployment=pull status=failed'
    exit 1
fi

bff_reference="$(read_environment_value BFF_IMAGE)"
finance_reference="$(read_environment_value FINANCE_IMAGE)"
debt_reference="$(read_environment_value DEBT_IMAGE)"
if [ -z "$bff_reference" ] || [ -z "$finance_reference" ] || [ -z "$debt_reference" ]; then
    log 'deployment=failed reason=image-reference-missing'
    exit 1
fi

candidate_bff_id="$(image_id "$bff_reference")"
candidate_finance_id="$(image_id "$finance_reference")"
candidate_debt_id="$(image_id "$debt_reference")"
candidate_fingerprint="$(fingerprint "$candidate_bff_id" "$candidate_finance_id" "$candidate_debt_id")"

if [ "$candidate_fingerprint" = "$current_fingerprint" ]; then
    log 'deployment=skipped reason=no-image-change'
    exit 0
fi

if [ -s "$failed_candidate_file" ] && [ "$(cat "$failed_candidate_file")" = "$candidate_fingerprint" ]; then
    log 'deployment=skipped reason=candidate-quarantined'
    exit 0
fi

log 'deployment=update status=starting'
if compose up --detach --wait --wait-timeout 240 finance-service debt-service bff &&
    compose exec -T edge wget --quiet --output-document=/dev/null http://127.0.0.1:8080/health; then
    rm -f "$failed_candidate_file"
    {
        printf 'deployed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'fingerprint=%s\n' "$candidate_fingerprint"
    } > "$last_successful_file"
    chmod 600 "$last_successful_file"
    log 'deployment=update status=healthy'
    exit 0
fi

printf '%s\n' "$candidate_fingerprint" > "$failed_candidate_file"
chmod 600 "$failed_candidate_file"
log 'deployment=update status=failed action=rollback'
if rollback; then
    exit 1
fi

log 'deployment=critical status=manual-intervention-required'
exit 1
