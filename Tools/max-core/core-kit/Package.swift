// swift-tools-version:5.9
import PackageDescription

// Проверочный SPM-пакет: ядро клиента без iOS-специфики (SwiftUI, UIKit, GRDB).
//
// Используется, чтобы в CI быстро прогонять тесты протокола на macOS:
//     swift test            (в этом каталоге)
//
// Core — зеркало MaxClient/Core, обновляется scripts/sync-core.sh|ps1.
// CLI-цели здесь нет намеренно: у main.swift верхнеуровневый `await`,
// который SwiftPM не пускает вместе с XCTest в одном пакете.

let package = Package(
    name: "MaxCoreKit",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MaxCore", path: "Core"),
        .testTarget(name: "MaxCoreTests", dependencies: ["MaxCore"], path: "Tests")
    ]
)
