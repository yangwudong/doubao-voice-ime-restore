// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "doubao-voice-ime-restore",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(name: "DoubaoVoiceRestore")
    ]
)
