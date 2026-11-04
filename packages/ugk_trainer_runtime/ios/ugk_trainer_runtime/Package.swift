// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ugk_trainer_runtime",
  platforms: [.iOS("15.0")],
  products: [
    .library(name: "ugk-trainer-runtime", targets: ["ugk_trainer_runtime"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "ugk_trainer_runtime",
      dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")]
    )
  ]
)
