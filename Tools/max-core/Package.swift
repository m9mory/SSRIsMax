// swift-tools-version:5.9
import PackageDescription

// CLI-харнесс ядра: те же Swift-файлы, что использует iOS-приложение,
// но без SwiftUI / UIKit / GRDB. Позволяет проверить протокол из терминала
// (macOS, Linux, Windows с установленным Swift toolchain).
//
// Core/ — зеркало MaxClient/Core, обновляется скриптом scripts/sync-core.sh.

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
            exclude: ["core-kit"]
        )
    ]
)
