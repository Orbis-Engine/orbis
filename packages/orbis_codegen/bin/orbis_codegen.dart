import 'dart:io';

import 'package:orbis_codegen/orbis_codegen.dart';
import 'package:path/path.dart' as p;

/// Generates component registration and a manifest for one package.
///
/// Usage: dart run orbis_codegen [package-root]
void main(List<String> arguments) {
  final root = arguments.isEmpty ? Directory.current.path : arguments.first;
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    stderr.writeln('No pubspec.yaml in $root.');
    exit(2);
  }

  final packageName = _packageName(pubspec.readAsStringSync()) ?? 'package';
  final result = const ComponentScanner().scanPackage(root);

  if (result.hasErrors) {
    stderr.writeln('orbis_codegen found ${result.errors.length} problem(s):');
    for (final error in result.errors) {
      stderr.writeln('  $error');
    }
    // Refused loudly rather than emitting something half right: a component
    // that does not generate is better than one that generates wrongly and is
    // discovered across a network session.
    exit(1);
  }

  const emitter = ComponentEmitter();
  final className = '${_pascal(packageName)}Components';

  final dartOut = File(p.join(root, 'lib', 'orbis_components.g.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync(emitter.dart(className, result.components));

  final manifestOut = File(p.join(root, 'orbis_components.json'))
    ..writeAsStringSync(emitter.manifest(packageName, result.components));

  stdout.writeln('orbis_codegen: ${result.components.length} component(s)');
  for (final component in result.components) {
    stdout.writeln(
      '  ${component.name.padRight(20)} '
      '${component.kind} x${component.arity}'
      '${component.replicated ? '  replicated' : ''}',
    );
  }
  stdout.writeln('  -> ${p.relative(dartOut.path, from: root)}');
  stdout.writeln('  -> ${p.relative(manifestOut.path, from: root)}');
}

String? _packageName(String pubspec) {
  for (final line in pubspec.split('\n')) {
    if (line.startsWith('name:')) return line.substring(5).trim();
  }
  return null;
}

String _pascal(String snake) => snake
    .split('_')
    .where((part) => part.isNotEmpty)
    .map((part) => part[0].toUpperCase() + part.substring(1))
    .join();
