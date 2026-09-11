import Foundation
import orbis_filament_native

#if canImport(FlutterMacOS)
import FlutterMacOS
#elseif canImport(Flutter)
import Flutter
#endif

/// The Gaussian splat clouds in a scene message, checked before C++ sees them.
///
/// In a file of its own rather than inside the plugin's Scene, because it is a
/// feature with its own shape: parallel arrays of clouds, plus the packed
/// records of whichever in-memory clouds have changed. Every length here is a
/// pointer the renderer walks, so a message that does not add up is refused
/// here, as a channel error, rather than read past the end there.
struct SplatMessage {
  /// Floats per cloud: a column-major transform, opacity and brightness.
  /// Must match OrbisSplats.stride in Dart and kSplatParams in C++.
  static let splatStride = 18

  /// Bytes per splat in the compact layout. Must match OrbisSplats.recordBytes
  /// and kSplatRecordBytes.
  static let recordBytes = 32

  let keys: [Int32]
  let flags: [Int32]
  let revisions: [Int32]
  let params: [Float]
  let paths: [String]
  let changed: [Int32]
  let changedCounts: [Int32]
  let data: Data

  /// Nil for a message that is malformed. A message with no splats at all is
  /// not malformed — it is every scene that never uses them — and decodes to
  /// an empty list.
  init?(arguments: [String: Any]) {
    keys = SplatMessage.int32s(arguments["splatKeys"]) ?? []
    flags = SplatMessage.int32s(arguments["splatFlags"]) ?? []
    revisions = SplatMessage.int32s(arguments["splatRevisions"]) ?? []
    params = SplatMessage.floats(arguments["splatParams"]) ?? []
    paths = arguments["splatPaths"] as? [String] ?? []
    changed = SplatMessage.int32s(arguments["splatChanged"]) ?? []
    changedCounts = SplatMessage.int32s(arguments["splatChangedCounts"]) ?? []
    data = (arguments["splatData"] as? FlutterStandardTypedData)?.data ?? Data()

    let count = keys.count
    let records = changedCounts.reduce(0) { $0 + Int($1) }
    guard flags.count == count, revisions.count == count,
          paths.count == count,
          params.count == count * SplatMessage.splatStride,
          changedCounts.count == changed.count,
          changedCounts.allSatisfy({ $0 >= 0 }),
          changed.allSatisfy({ keys.contains($0) }),
          data.count == records * SplatMessage.recordBytes else { return nil }
  }

  /// Hands the clouds to the renderer. Skipped when there are none and the
  /// renderer holds none, so a scene without splats costs nothing here.
  func apply(to renderer: OrbisRenderer) {
    let count = keys.count
    if count == 0 && !renderer.hasSplats { return }

    // An empty array has no base address, and the renderer's pointers are not
    // nullable; nothing is read through these when the counts are zero.
    let keys = count == 0 ? [Int32(0)] : self.keys
    let flags = count == 0 ? [Int32(0)] : self.flags
    let revisions = count == 0 ? [Int32(0)] : self.revisions
    let params = count == 0 ? [Float(0)] : self.params
    let changed = self.changed.isEmpty ? [Int32(0)] : self.changed
    let changedCounts = self.changedCounts.isEmpty ? [Int32(0)] : self.changedCounts
    let bytes = data.isEmpty ? Data([0]) : data

    keys.withUnsafeBufferPointer { keyPointer in
      flags.withUnsafeBufferPointer { flagPointer in
        revisions.withUnsafeBufferPointer { revisionPointer in
          params.withUnsafeBufferPointer { paramPointer in
            changed.withUnsafeBufferPointer { changedPointer in
              changedCounts.withUnsafeBufferPointer { countPointer in
                bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                  renderer.applySplats(
                    keyPointer.baseAddress!,
                    flags: flagPointer.baseAddress!,
                    revisions: revisionPointer.baseAddress!,
                    params: paramPointer.baseAddress!,
                    paths: self.paths,
                    changed: changedPointer.baseAddress!,
                    changedCounts: countPointer.baseAddress!,
                    changedCount: UInt32(self.changed.count),
                    data: raw.bindMemory(to: UInt8.self).baseAddress!,
                    dataLength: data.count,
                    count: UInt32(count))
                }
              }
            }
          }
        }
      }
    }
  }

  private static func int32s(_ value: Any?) -> [Int32]? {
    guard let typed = value as? FlutterStandardTypedData, typed.type == .int32
    else { return nil }
    return typed.data.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
  }

  private static func floats(_ value: Any?) -> [Float]? {
    guard let typed = value as? FlutterStandardTypedData, typed.type == .float32
    else { return nil }
    return typed.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }
}
