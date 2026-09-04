import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

import 'model.dart';

/// Finds component declarations in a package's sources.
///
/// Parses rather than resolves. Resolution would need the package's whole
/// dependency graph analysed, which is slow and — more to the point — would
/// stop a manifest being readable across a package boundary without building
/// that package. What a component declaration says is on its face.
class ComponentScanner {
  const ComponentScanner();

  /// Scans `lib/` under [packageRoot].
  ScanResult scanPackage(String packageRoot) {
    final lib = Directory(p.join(packageRoot, 'lib'));
    if (!lib.existsSync()) {
      return ScanResult(const [], const []);
    }

    final components = <ComponentDeclaration>[];
    final errors = <ComponentError>[];

    final files =
        lib
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          // Sorted so a manifest is reproducible rather than filesystem-ordered.
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final relative = p.relative(file.path, from: packageRoot);
      scanSource(file.readAsStringSync(), relative, components, errors);
    }

    return ScanResult(components, errors);
  }

  /// Scans one source string. Exposed so tests need no files on disk.
  void scanSource(
    String source,
    String path,
    List<ComponentDeclaration> into,
    List<ComponentError> errors,
  ) {
    final unit = parseString(content: source, throwIfDiagnostics: false).unit;

    for (final declaration in unit.declarations) {
      if (declaration is! ClassDeclaration) continue;
      final annotation = _componentAnnotation(declaration);
      if (annotation == null) continue;

      final className = declaration.name.lexeme;
      final fields = <String>[];
      String? dartType;
      String? mismatch;

      for (final member in declaration.members) {
        if (member is! FieldDeclaration || member.isStatic) continue;
        final type = member.fields.type?.toSource();
        if (type == null) {
          mismatch ??=
              'field "${member.fields.variables.first.name.lexeme}" '
              'has no written type; the generator reads declarations rather '
              'than inferring them';
          continue;
        }
        for (final variable in member.fields.variables) {
          dartType ??= type;
          if (type != dartType) {
            mismatch ??=
                'fields are $dartType and $type; a component is one '
                'column, so every field must share a type. Split it into two '
                'components instead';
          }
          fields.add(variable.name.lexeme);
        }
      }

      // A field the generator could not read is a more useful thing to say
      // than "no fields", which is what it looks like once that field is
      // skipped.
      if (mismatch != null) {
        errors.add(ComponentError(path, className, mismatch));
        continue;
      }
      if (fields.isEmpty) {
        errors.add(ComponentError(path, className, 'has no instance fields'));
        continue;
      }

      final explicitKind = _stringArgument(annotation, 'kind');
      final kind = explicitKind ?? _inferKind(dartType!);
      if (kind == null) {
        errors.add(
          ComponentError(
            path,
            className,
            'fields are $dartType, which has no default storage. Give the '
            'annotation an explicit kind',
          ),
        );
        continue;
      }

      into.add(
        ComponentDeclaration(
          name: _stringLiteral(annotation, 'name') ?? className,
          className: className,
          kind: kind,
          fields: fields,
          replicated: _boolArgument(annotation, 'replicated') ?? false,
          ownerWritable: _boolArgument(annotation, 'ownerWritable') ?? false,
          source: path,
        ),
      );
    }
  }

  Annotation? _componentAnnotation(ClassDeclaration declaration) {
    for (final annotation in declaration.metadata) {
      if (annotation.name.name == 'OrbisComponent') return annotation;
    }
    return null;
  }

  /// Dart's numeric types do not say how wide they should be stored, so these
  /// are the defaults a game overrides when it wants something else.
  String? _inferKind(String dartType) => switch (dartType) {
    'double' => 'float32',
    'int' => 'int32',
    'bool' => 'uint8',
    _ => null,
  };

  Expression? _argument(Annotation annotation, String name) {
    for (final argument in annotation.arguments?.arguments ?? const []) {
      if (argument is NamedExpression && argument.name.label.name == name) {
        return argument.expression;
      }
    }
    return null;
  }

  String? _stringLiteral(Annotation annotation, String name) {
    final expression = _argument(annotation, name);
    return expression is SimpleStringLiteral ? expression.value : null;
  }

  bool? _boolArgument(Annotation annotation, String name) {
    final expression = _argument(annotation, name);
    return expression is BooleanLiteral ? expression.value : null;
  }

  /// Reads `OrbisKind.float64` as `float64`.
  String? _stringArgument(Annotation annotation, String name) {
    final expression = _argument(annotation, name);
    if (expression is PrefixedIdentifier &&
        expression.prefix.name == 'OrbisKind') {
      return expression.identifier.name;
    }
    return null;
  }
}
