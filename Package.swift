// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "termdown",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-cmark", revision: "437611671145d47e6d9679761b8a5987766f4ae5")
  ],
  targets: [
    .target(name: "TermDownCore"),
    .target(
      name: "TermDownDocument",
      dependencies: [
        "TermDownCore",
        .product(name: "cmark-gfm", package: "swift-cmark"),
        .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
      ]),
    .target(name: "TermDownLayout", dependencies: ["TermDownDocument"]),
    .target(
      name: "TermDownRender",
      dependencies: ["TermDownCore", "TermDownDocument", "TermDownLayout"],
      resources: [.copy("Resources/highlight.min.js"), .copy("Resources/THIRD_PARTY_NOTICES")]),
    .target(name: "TermDownSystem"),
    .target(
      name: "TermDownDisplay", dependencies: ["TermDownCore", "TermDownLayout", "TermDownRender", "TermDownSystem"]),
    .target(
      name: "TermDownInteraction",
      dependencies: ["TermDownCore", "TermDownDocument", "TermDownLayout", "TermDownRender", "TermDownSystem"]),
    .target(
      name: "TermDownMermaid",
      dependencies: ["TermDownCore"],
      resources: [.copy("Resources/mermaid")]),
    .target(
      name: "TermDownHost",
      dependencies: [
        "TermDownCore", "TermDownDisplay", "TermDownInteraction", "TermDownLayout", "TermDownMermaid", "TermDownRender",
      ]),
    .executableTarget(
      name: "termdown",
      dependencies: [
        "TermDownCore", "TermDownDisplay", "TermDownHost", "TermDownInteraction", "TermDownMermaid", "TermDownRender",
        "TermDownSystem",
      ]),
    .executableTarget(name: "TermDownHandler", dependencies: ["TermDownCore"]),
    .testTarget(
      name: "TermDownCoreTests",
      dependencies: ["TermDownCore"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "TermDownDocumentTests",
      dependencies: ["TermDownDocument"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "TermDownLayoutTests",
      dependencies: ["TermDownLayout", "TermDownDocument"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "TermDownRasterTests",
      dependencies: ["TermDownRender", "TermDownLayout", "TermDownCore", "TermDownDocument", "TermDownMermaid"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "TermDownDisplayTests",
      dependencies: [
        "TermDownDisplay", "TermDownRender", "TermDownLayout", "TermDownCore", "TermDownSystem",
      ],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "TermDownInteractionTests",
      dependencies: ["TermDownInteraction", "TermDownLayout", "TermDownRender", "TermDownCore", "TermDownDocument"]),
    .testTarget(
      name: "TermDownMermaidTests",
      dependencies: ["TermDownMermaid", "TermDownCore"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "TermDownHostTests",
      dependencies: [
        "TermDownHost", "TermDownCore", "TermDownDisplay", "TermDownInteraction", "TermDownLayout", "TermDownMermaid",
        "TermDownRender",
      ]),
  ]
)
