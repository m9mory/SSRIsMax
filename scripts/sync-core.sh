#!/usr/bin/env bash
# Пересобирает зеркало ядра для CLI (Tools/max-core).
#
# Источник правды — MaxClient/Core. В Tools/max-core/Core копируются только
# файлы, не зависящие от SwiftUI, UIKit и GRDB. Зеркало не редактируйте:
# правки будут перезаписаны.
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
    if [[ $stale -eq 0 ]]; then
        echo "Зеркало актуально."
    else
        exit 1
    fi
    exit 0
fi

rm -rf "$DST"
mkdir -p "$DST"
for f in "${FILES[@]}"; do
    cp "$SRC/$f" "$DST/$(basename "$f")"
done

echo "Скопировано ${#FILES[@]} файлов в $DST"
