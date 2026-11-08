#!/usr/bin/env bash
# Пересобирает зеркало ядра для CLI (Tools/max-core).
#
# Источник правды — MaxClient/Core. В Tools/max-core/Core копируются только
# файлы, не зависящие от SwiftUI, UIKit, GRDB и Security. Зеркало не
# редактируйте: правки будут перезаписаны.
#
# CredentialStoreProtocol.swift копируется: он без Security, и протокол
# MaxCredentialStore должен быть виден и приложению, и CLI.
# MaxMemoryCredentialStore.swift — ТОЛЬКО в зеркале (in-memory класс для тестов).
#
# Использование:
#   scripts/sync-core.sh            # скопировать
#   scripts/sync-core.sh --verify   # только проверить, что зеркало актуально
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="MaxClient/Core"
DST="Tools/max-core/Core"

FILES=(
    "Protocol/MessagePack.swift"
    "Protocol/MaxProtocol.swift"
    "Protocol/MaxParser.swift"
    "Models/Models.swift"
    "Network/MaxTransport.swift"
    "Network/MaxWebSocketTransport.swift"
    "Network/MaxTCPTransport.swift"
    "Auth/MaxAuthService.swift"
    "Design/PhoneFormatter.swift"
    "Storage/CredentialStoreProtocol.swift"
)

# Файлы, которые существуют только в зеркале (им нечего копировать
# из приложения — там их заменяет Keychain-версия).
MIRROR_ONLY=(
    "MaxMemoryCredentialStore.swift"
)

verify=0
if [[ "${1:-}" == "--verify" ]]; then
    verify=1
fi

if [[ $verify -eq 1 ]]; then
    stale=0
    for f in "${FILES[@]}"; do
        if ! cmp -s "$SRC/$f" "$DST/$(basename "$f")"; then
            echo "устарело: $f"
            stale=1
        fi
    done
    for f in "${MIRROR_ONLY[@]}"; do
        if [[ ! -f "$DST/$f" ]]; then
            echo "отсутствует: $DST/$f"
            stale=1
        fi
    done
    if [[ $stale -eq 0 ]]; then
        echo "Зеркало актуально."
    else
        exit 1
    fi
    exit 0
fi

mkdir -p "$DST"

# Удаляем только управляемые файлы. Прежний `rm -rf "$DST"` стирал и
# MIRROR_ONLY, после чего проверка ниже всегда падала.
for f in "${FILES[@]}"; do
    rm -f "$DST/$(basename "$f")"
done

for f in "${FILES[@]}"; do
    cp "$SRC/$f" "$DST/$(basename "$f")"
done

# MIRROR_ONLY не трогаем — они уже на месте; проверяем, что не пропали.
for f in "${MIRROR_ONLY[@]}"; do
    if [[ ! -f "$DST/$f" ]]; then
        echo "ОШИБКА: $DST/$f отсутствует" >&2
        echo "Восстановите его из git: git checkout -- $DST/$f" >&2
        exit 1
    fi
done

echo "Скопировано ${#FILES[@]} файлов в $DST"
