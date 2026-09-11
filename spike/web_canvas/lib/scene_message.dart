// The spike's scene message: what Dart tells the renderer, as bytes.
//
// The real Orbis scene message is far richer, but on the web it would cross
// the same way: encoded here, handed over as one typed array, decoded on the
// other side. Here the other side is apply() in web/orbis_filament_view.js;
// on route [ii] of README.md it would be the C++ renderer core compiled to
// WebAssembly, reading the same bytes out of its own heap.
//
// Layout, little-endian and four-byte aligned: a run of commands, each
//   u32 opcode, u32 entity id, u32 payload length in floats, f32 x length.
// The length lets a reader step over an opcode it does not know, so either
// side can grow first.
//
// Pure Dart (no web imports), so the layout is pinned by a VM test.
library;

import 'dart:typed_data';

/// Opcodes, mirrored in web/orbis_filament_view.js.
abstract final class SceneOp {
  /// r, g, b: sRGB, 0 to 1.
  static const int setBaseColour = 1;

  /// Radians per second about the entity's Y axis.
  static const int setSpin = 2;
}

/// One message: a batch of commands encoded together and sent in one crossing.
class SceneMessage {
  final List<(int op, int entity, List<double> floats)> _commands = [];

  void setBaseColour(int entity, double r, double g, double b) =>
      _commands.add((SceneOp.setBaseColour, entity, [r, g, b]));

  void setSpin(int entity, double radiansPerSecond) =>
      _commands.add((SceneOp.setSpin, entity, [radiansPerSecond]));

  Uint8List encode() {
    var size = 0;
    for (final (_, _, floats) in _commands) {
      size += 12 + 4 * floats.length;
    }
    final bytes = ByteData(size);
    var at = 0;
    for (final (op, entity, floats) in _commands) {
      bytes
        ..setUint32(at, op, Endian.little)
        ..setUint32(at + 4, entity, Endian.little)
        ..setUint32(at + 8, floats.length, Endian.little);
      at += 12;
      for (final value in floats) {
        bytes.setFloat32(at, value, Endian.little);
        at += 4;
      }
    }
    return bytes.buffer.asUint8List();
  }
}
