// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "nitro_printing_example",
  platforms: [.macOS(.v10_15)],
  products: [
    .library(name: "nitro-printing-example", targets: ["nitro_printing_example"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "NitroPrintingExampleCpp",
      path: "Sources/NitroPrintingExampleCpp",
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("include"),
        .unsafeFlags(["-std=c++17"])
      ]
    ),
    .target(
      name: "nitro_printing_example",
      dependencies: [
        "NitroPrintingExampleCpp",
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      path: "Sources/NitroPrintingExample"
    )
  ]
)
