import 'dart:io';

import 'package:orbis_mesh/orbis_mesh.dart';

/// Writes one `.glb` per shape, for looking at in the editor.
///
/// Here rather than in a test because the question it answers is one only the
/// renderer can: a file that every check in this package passes can still be
/// one Filament refuses to load, and the only way to know is to load it.
void main(List<String> args) {
  final into = Directory(args.isEmpty ? 'build/shapes' : args.first)
    ..createSync(recursive: true);

  for (final kind in ShapeKind.values) {
    final mesh = Shape(kind: kind, width: 2, height: 2, depth: 2).build();
    final file = File('${into.path}/${kind.name}.glb')
      ..writeAsBytesSync(mesh.toGlb(name: kind.name));
    stdout.writeln(
      '${kind.name}: ${mesh.faceCount} faces, ${file.lengthSync()} bytes',
    );
  }
}
