// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "CodexLimitMenuBar",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(
      name: "CodexLimitMenuBar",
      targets: ["CodexLimitMenuBar"]
    )
  ],
  targets: [
    .executableTarget(
      name: "CodexLimitMenuBar"
    ),
    .testTarget(
      name: "CodexLimitMenuBarTests",
      dependencies: ["CodexLimitMenuBar"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
