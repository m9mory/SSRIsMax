// swift-tools-version:5.9
import PackageDescription

// Единый SPM-пакет для офлайн-проверки ядра клиента (без SwiftUI, UIKit, GRDB).
//
// Почему один пакет, а не два:
// SwiftPM запрещает таргету выходить за корень пакета. Раньше был вложенный
// пакет Tools/max-core/core-kit с `path: "../Core"` — это валилось с
// «target 'MaxCore' is outside the package root». Поэтому ядро и тесты
// живут в одном пакете, а CLI-цель отдельная.
//
// Внимание: порядок аргументов в PackageDescription фиксирован —
// `exclude` обязан идти ДО `sources`, иначе манифест не компилируется.
//
// Core/ — зеркало MaxClient/Core, обновляется scripts/sync-core.sh|ps1.

let package = Package(
    name: "max-core",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "max-core", targets: ["max-core"]),
        .library(name: "MaxCore", targets: ["MaxCore"])
    ],
    targets: [
        // Ядро протокола: то же, что собирает iOS-приложение.
        .target(
            name: "MaxCore",
            path: "Core"
        ),
        // CLI-харнесс: encode/decode протокола из терминала.
        // Зависит от ядра, чтобы типы были в одном модуле проекта.
        .executableTarget(
            name: "max-core",
            path: ".",
            exclude: ["Core", "core-kit"],
            sources: ["main.swift"],
            dependencies: ["MaxCore"]
        ),
        // Офлайн-тесты: XCTest рядом с ядром, без CLI-цели
        // (у main.swift верхнеуровневый код, несовместимый с тестами).
        .testTarget(
            name: "MaxCoreTests",
            path: "Tests",
            dependencies: ["MaxCore"]
        )
    ]
)
