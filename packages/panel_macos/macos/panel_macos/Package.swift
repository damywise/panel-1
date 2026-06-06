// swift-tools-version: 5.9
// Swift Package Manager manifest for the panel_macos Flutter plugin.
// (Flutter also supports the CocoaPods podspec alongside this; both compile the
// same sources under Sources/panel_macos.)
import PackageDescription

let package = Package(
  name: "panel_macos",
  platforms: [
    .macOS("10.14"),
  ],
  products: [
    .library(name: "panel-macos", targets: ["panel_macos"]),
  ],
  dependencies: [],
  targets: [
    .target(
      name: "panel_macos",
      dependencies: []
    ),
  ]
)
