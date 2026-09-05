// swift-tools-version: 5.9

import Foundation
import PackageDescription

/// Filament arrives as one binary target rather than twenty archives.
///
/// Swift Package Manager has no way to say "these static libraries and that
/// include directory"; what it takes is an xcframework. `setup.sh` builds one
/// out of the SDK it fetches, because a package plugin runs sandboxed with no
/// network and could never fetch a hundred megabytes of renderer itself.
let filament = "third_party/Filament.xcframework"

// Checked here so a fresh clone is told what to run, rather than being handed
// whatever SwiftPM says about a path that is not there.
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
if !FileManager.default.fileExists(atPath: here.appendingPathComponent(filament).path) {
  fatalError(
    """

    orbis_filament: \(filament) is missing.

    Filament is fetched, not vendored. Build it once:

        bash packages/orbis_filament/macos/setup.sh

    """
  )
}

let package = Package(
  name: "orbis_filament",
  platforms: [
    .macOS("10.15")
  ],
  products: [
    .library(name: "orbis-filament", targets: ["orbis_filament"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    // The plugin: the method channel, the display link, and the texture
    // registration. Swift, because that is what Flutter's macOS API is.
    .target(
      name: "orbis_filament",
      dependencies: [
        "orbis_filament_native",
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ]
    ),
    // The renderer. A separate target because a Swift Package Manager target
    // holds one language, and this is Objective-C++ — which is also why the
    // header it publishes is free of C++.
    .target(
      name: "orbis_filament_native",
      dependencies: ["Filament"],
      cSettings: [
        .headerSearchPath("include")
      ],
      linkerSettings: [
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("QuartzCore"),
        .linkedFramework("IOSurface"),
        // bluegl's fallback backend; Filament links it whether or not the
        // Metal backend is the one in use.
        .linkedFramework("OpenGL"),
      ]
    ),
    .binaryTarget(name: "Filament", path: filament),
  ],
  cxxLanguageStandard: .cxx17
)
