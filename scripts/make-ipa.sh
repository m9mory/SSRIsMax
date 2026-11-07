#!/usr/bin/env bash
# Упаковка собранного .app в не подписанный .ipa для личного сайдлоада
# (SideStore / AltStore / Sideloadly / TrollStore).
#
# Подписать IPA нельзя без вашего сертификата и provisioning-профиля,
# поэтому пакет собирается как Payload/MAX.app и подписывается уже
# на устройстве или инструментом сайдлоада.
#
# Использование: scripts/make-ipa.sh <путь к .app> <путь к .ipa>
set -euo pipefail

APP="${1:?usage: make-ipa.sh <App.app> <out.ipa>}"
IPA="${2:?usage: make-ipa.sh <App.app> <out.ipa>}"

if [[ ! -d "$APP" ]]; then
    echo "Не найдено приложение: $APP" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Payload"
cp -R "$APP" "$work/Payload/"
rm -rf "$work/Payload/$(basename "$APP")/_CodeSignature"

# zip обязателен: симлинки внутри бандла не должны разворачиваться.
(cd "$work" && zip -qry "$IPA" Payload)

echo "IPA: $IPA ($(du -h "$IPA" | cut -f1))"
