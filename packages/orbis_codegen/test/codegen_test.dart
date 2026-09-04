import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:orbis_codegen/orbis_codegen.dart';
import 'package:test/test.dart';

/// Parses generated code and fails with the compiler's own complaint.
///
/// Checking for substrings proved not to be enough: an initialiser list with a
/// colon before every entry contains everything you would grep for and does not
/// parse. Generated code has to be run through a parser, not read.
void expectParses(String code) {
  final result = parseString(content: code, throwIfDiagnostics: false);
  expect(
    result.errors,
    isEmpty,
    reason: result.errors.map((e) => e.message).join('; '),
  );
}

ScanResult scan(String source) {
  final components = <ComponentDeclaration>[];
  final errors = <ComponentError>[];
  const ComponentScanner().scanSource(
    source,
    'lib/test.dart',
    components,
    errors,
  );
  return ScanResult(components, errors);
}

void main() {
  group('scanning', () {
    test('infers float32 from double fields', () {
      final result = scan('''
        @OrbisComponent()
        class Position {
          double x = 0;
          double y = 0;
          double z = 0;
        }
      ''');

      expect(result.errors, isEmpty);
      final component = result.components.single;
      expect(component.name, 'Position');
      expect(component.kind, 'float32');
      expect(component.arity, 3);
      expect(component.fields, ['x', 'y', 'z']);
    });

    test('reads several variables from one declaration', () {
      final result = scan('''
        @OrbisComponent()
        class Velocity { double x, y, z; }
      ''');
      expect(result.components.single.fields, ['x', 'y', 'z']);
    });

    test('infers int32 from int and uint8 from bool', () {
      final result = scan('''
        @OrbisComponent()
        class Health { int current; int max; }

        @OrbisComponent()
        class Flags { bool visible; }
      ''');
      expect(result.components.map((c) => c.kind), ['uint8', 'int32']);
    });

    test('an explicit name and kind win over what is inferred', () {
      final result = scan('''
        @OrbisComponent(name: 'WorldMatrix', kind: OrbisKind.float64)
        class Matrix { double a, b; }
      ''');
      final component = result.components.single;
      expect(component.name, 'WorldMatrix');
      expect(component.className, 'Matrix');
      expect(component.kind, 'float64');
    });

    test('carries replication flags through', () {
      final result = scan('''
        @OrbisComponent(replicated: true, ownerWritable: true)
        class Input { double throttle; }
      ''');
      expect(result.components.single.replicated, isTrue);
      expect(result.components.single.ownerWritable, isTrue);
    });

    test('ignores classes without the annotation', () {
      final result = scan('class Plain { double x; }');
      expect(result.components, isEmpty);
      expect(result.errors, isEmpty);
    });

    test('ignores static fields', () {
      final result = scan('''
        @OrbisComponent()
        class Position {
          static const int stride = 3;
          double x, y, z;
        }
      ''');
      expect(result.components.single.fields, ['x', 'y', 'z']);
    });

    test('components come back sorted, so a manifest is reproducible', () {
      final result = scan('''
        @OrbisComponent()
        class Zeta { double a; }
        @OrbisComponent()
        class Alpha { double a; }
      ''');
      expect(result.components.map((c) => c.name), ['Alpha', 'Zeta']);
    });
  });

  group('refusals', () {
    test('mixed field types are refused with a way forward', () {
      final result = scan('''
        @OrbisComponent()
        class Body { double mass; int layer; }
      ''');
      expect(result.components, isEmpty);
      expect(result.errors.single.message, contains('Split it into two'));
    });

    test('a component with no fields is refused', () {
      final result = scan('''
        @OrbisComponent()
        class Marker {}
      ''');
      expect(result.errors.single.message, contains('no instance fields'));
    });

    test('a type with no default storage is refused', () {
      final result = scan('''
        @OrbisComponent()
        class Name { String value; }
      ''');
      expect(result.errors.single.message, contains('explicit kind'));
    });

    test('an untyped field is refused rather than guessed at', () {
      final result = scan('''
        @OrbisComponent()
        class Loose { var x; }
      ''');
      expect(result.errors.single.message, contains('no written type'));
    });
  });

  group('the manifest', () {
    test('is plain data another tool can read', () {
      final result = scan('''
        @OrbisComponent(replicated: true, ownerWritable: true)
        class Velocity { double x, y, z; }
        @OrbisComponent()
        class Health { int current; }
      ''');

      final json =
          jsonDecode(
                const ComponentEmitter().manifest('my_game', result.components),
              )
              as Map<String, Object?>;

      expect(json['formatVersion'], 1);
      expect(json['package'], 'my_game');

      final components = json['components']! as List<Object?>;
      expect(components, hasLength(2));

      final health = components.first! as Map<String, Object?>;
      expect(health['name'], 'Health');
      expect(health['kind'], 'int32');
      expect(health['arity'], 1);
      expect(health['replicated'], isFalse);
      expect(
        health.containsKey('ownerWritable'),
        isFalse,
        reason:
            'owner-writability is meaningless without replication and '
            'should not imply otherwise',
      );

      final velocity = components[1]! as Map<String, Object?>;
      expect(velocity['ownerWritable'], isTrue);
      expect(velocity['fields'], ['x', 'y', 'z']);
    });
  });

  group('the generated Dart', () {
    test('registers each component with its inferred layout', () {
      final result = scan('''
        @OrbisComponent(replicated: true, ownerWritable: true)
        class Velocity { double x, y, z; }
      ''');
      final code = const ComponentEmitter().dart(
        'GameComponents',
        result.components,
      );

      expect(code, contains('class GameComponents'));
      expect(
        code,
        contains(
          "world.registerComponent('Velocity', kind: ComponentKind.float32, arity: 3)",
        ),
      );
      expect(
        code,
        contains("Set<String> get ownerWritable => const {'Velocity'};"),
      );
      expect(code, contains('extension type VelocityColumn(Float32List data)'));
    });

    test('offsets a column accessor by the field position', () {
      final result = scan('''
        @OrbisComponent()
        class Position { double x, y, z; }
      ''');
      final code = const ComponentEmitter().dart('C', result.components);

      expect(code, contains('double x(int row) => data[row * 3];'));
      expect(code, contains('double z(int row) => data[row * 3 + 2];'));
      expect(
        code,
        contains(
          'void setZ(int row, double value) => data[row * 3 + 2] = value;',
        ),
      );
    });

    test('parses — including the initialiser list, which substrings miss', () {
      final result = scan('''
        @OrbisComponent(replicated: true, ownerWritable: true)
        class Velocity { double x, y, z; }
        @OrbisComponent()
        class Health { int current; }
        @OrbisComponent(kind: OrbisKind.int64)
        class NetworkId { int value; }
      ''');
      expectParses(const ComponentEmitter().dart('C', result.components));
    });

    test('parses with a single component', () {
      final result = scan('@OrbisComponent() class Only { double a; }');
      expectParses(const ComponentEmitter().dart('C', result.components));
    });

    test('parses with no components at all', () {
      expectParses(const ComponentEmitter().dart('C', const []));
    });

    test('a package with no components still generates something usable', () {
      final code = const ComponentEmitter().dart('Empty', const []);
      expect(code, contains('Empty.register(World world);'));
      expect(code, contains('get all => const []'));
    });
  });
}
