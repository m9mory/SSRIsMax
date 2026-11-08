// swift-tools-version:5.9
import PackageDescription

// CLI-харнесс ядра: те же Swift-файлы, что использует iOS-приложение,
// но без SwiftUI / UIKit / GRDB. Позволяет проверить протокол из терминала
// (macOS, Linux, Windows с установленным Swift toolchain).
//
// Core/ — зеркало MaxClient/Core, обновляется скриптом scripts/sync-core.sh.
//
// Источники перечислены явно: `sources: ["Core", "main.swift"]`.
// Раньше здесь было `path: "."` + `exclude: ["core-kit"]`, и SwiftPM
// не включал `Core/` в таргет — файлы ядра не компилировались, а
// `main.swift` ссылался на несуществующие типы (ошибки вида
// «cannot find 'nowMillis' in scope» и «MPValue has no accessible
// initializers» при том, что код был на месте).

let package = Package(
    name: "max-core",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "max-core", targets: ["max-core"])
    ],
    targets: [
        .executableTarget(
            name: "max-core",
            path: ".",
            sources: ["Core", "main.swift"]
        )
    ]
)
