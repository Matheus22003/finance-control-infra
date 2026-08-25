#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo 'Informe o endereço LAN do ZimaOS.' >&2
  exit 1
fi

zimaos_host="$1"
case "$zimaos_host" in
  *[!A-Za-z0-9.-]*|'')
    echo 'Endereço LAN inválido.' >&2
    exit 1
    ;;
esac

link_file='/var/lib/casaos/1/link.json'
backup_file='/var/lib/casaos/1/link.json.finance-control.bak'
temporary_file="$(mktemp /var/lib/casaos/1/link.json.XXXXXX)"
uptime_kuma_icon='https://cdn.jsdelivr.net/gh/IceWhaleTech/CasaOS-AppStore@main/Apps/UptimeKuma/icon.png'

cleanup() {
  rm -f "$temporary_file"
}

trap cleanup EXIT HUP INT TERM

shortcut_result='already_present'
if ! grep -Fq '"name":"Uptime Kuma"' "$link_file"; then
  if ! grep -Eq '^\[.*\]$' "$link_file"; then
    echo 'O arquivo de links do ZimaOS não possui o formato esperado.' >&2
    exit 1
  fi

  cp -p "$link_file" "$backup_file"
  shortcut="{\"hostname\":\"http://${zimaos_host}:3001\",\"name\":\"Uptime Kuma\",\"icon\":\"${uptime_kuma_icon}\",\"app_type\":\"LinkApp\",\"status\":\"running\"}"
  if [ "$(cat "$link_file")" = '[]' ]; then
    printf '[%s]\n' "$shortcut" >"$temporary_file"
  else
    sed "s|]$|,${shortcut}]|" "$link_file" >"$temporary_file"
  fi
  install -o root -g root -m 644 "$temporary_file" "$link_file"
  shortcut_result='created'
fi

systemctl restart zimaos-user.service
systemctl is-active --quiet zimaos-user.service
printf 'uptime_kuma_shortcut=%s\n' "$shortcut_result"
