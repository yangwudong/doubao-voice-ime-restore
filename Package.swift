// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "doubao-voice-ime-restore",
    platforms: [.macOS(.v11)],
    targets: [
        // Pure decision logic: the state machine and the pill geometry.
        // No system calls, so every timing scenario is unit-testable.
        .target(name: "DoubaoVoiceRestoreCore"),
        // System glue: TIS, CGWindowList, timers, logging, CLI.
        .executableTarget(
            name: "DoubaoVoiceRestore",
            dependencies: ["DoubaoVoiceRestoreCore"]
        ),
        .testTarget(
            name: "DoubaoVoiceRestoreCoreTests",
            dependencies: ["DoubaoVoiceRestoreCore"]
        ),
    ]
)
