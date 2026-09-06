import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:orbis_core/orbis_core.dart';
import 'package:orbis_native/orbis_native.dart';
import 'package:orbis_native/src/host.dart' show OrbisScriptHost;
import 'package:test/test.dart';

/// A script that counts into a component, so a test can see that it ran by
/// looking at the world rather than at what it printed.
///
/// Two doubles rather than a double and an int, so Dart can read the column
/// back as one typed view — the component layout is the contract between the
/// two sides here just as much as the function table is.
const String counter = '''
#include "orbis_script.h"

struct Ticks { double seconds; double calls; };

namespace {
OrbisComponent tick;
OrbisEntity subject;
}

ORBIS_SCRIPT {
  tick = orbis::component<Ticks>("Ticks");
  subject = orbis::spawn();
  orbis::give(subject, tick, Ticks{0.0, 0.0});
  orbis::log("counter: started");
}

extern "C" void orbis_step(double delta) {
  Ticks *held = orbis::get<Ticks>(subject, tick);
  if (held == nullptr) return;
  held->seconds += delta;
  held->calls += 1.0;
}

extern "C" void orbis_stop(void) { orbis::log("counter: stopped"); }
''';

/// Reads a data object every frame, so values a designer edits reach C++.
const String reader = '''
#include "orbis_script.h"

struct Speed { double value; double on; };

namespace {
OrbisComponent speed;
OrbisEntity subject;
}

ORBIS_SCRIPT {
  speed = orbis::component<Speed>("Speed");
  subject = orbis::spawn();
  orbis::give(subject, speed, Speed{0.0, 0.0});
}

extern "C" void orbis_step(double delta) {
  (void)delta;
  Speed *held = orbis::get<Speed>(subject, speed);
  held->value = orbis::number("ball.odata", "speed", -1.0);
  held->on = orbis::toggle("ball.odata", "bouncy", false) ? 1.0 : 0.0;
  const char *label = orbis::text("ball.odata", "label");
  if (label != nullptr) orbis::log(label);
}

extern "C" void orbis_stop(void) {}
''';

class _Values implements ScriptValues {
  _Values([this.numbers = const {}, this.toggles = const {}, this.texts = const {}]);

  final Map<String, double> numbers;
  final Map<String, bool> toggles;
  final Map<String, String> texts;

  @override
  double number(String asset, String key, double fallback) =>
      numbers['$asset/$key'] ?? fallback;

  @override
  bool toggle(String asset, String key, bool fallback) =>
      toggles['$asset/$key'] ?? fallback;

  @override
  String? text(String asset, String key) => texts['$asset/$key'];
}

void main() {
  late Directory root;
  late World world;
  late List<String> said;

  setUp(() {
    root = Directory.systemTemp.createTempSync('orbis_script');
    world = World();
    said = [];
  });

  tearDown(() {
    world.dispose();
    root.deleteSync(recursive: true);
  });

  File write(String name, String source) =>
      File('${root.path}/$name.cpp')..writeAsStringSync(source);

  ScriptRunner runner({ScriptValues values = const NoValues()}) => ScriptRunner(
        world: world,
        build: Directory('${root.path}/build'),
        values: values,
        onLog: said.add,
      );

  /// A component the C++ side registered, looked up by registering the same
  /// layout — which the core answers with the existing id.
  ComponentType pair(String name) =>
      world.registerComponent(name, kind: ComponentKind.float64, arity: 2);

  /// The rows of a component, as the script left them.
  Float64List rows(String name) {
    final query = world.query([pair(name)]);
    final chunk = query.chunks.single;
    return chunk.float64(0);
  }

  test('there is a compiler to test with', () {
    expect(Toolchain.find(), isNotNull,
        reason: 'these tests compile real C++; with no toolchain they would '
            'pass by not running');
  });

  group('building', () {
    test('a script compiles and starts', () {
      final host = runner();
      addTearDown(host.dispose);

      final built = host.add(write('counter', counter));

      expect(built.ok, isTrue, reason: built.output);
      expect(said, contains('counter: started'));
    });

    test('what it did is in the world, not just in what it printed', () {
      final host = runner();
      addTearDown(host.dispose);
      host.add(write('counter', counter));

      expect(world.entityCount, 1);
      expect(rows('Ticks'), hasLength(2));
    });

    test('stepping reaches it', () {
      final host = runner();
      addTearDown(host.dispose);
      host.add(write('counter', counter));

      host.step(0.5);
      host.step(0.25);

      final ticks = rows('Ticks');
      expect(ticks[0], closeTo(0.75, 1e-9));
      expect(ticks[1], 2);
    });

    test('a script that does not compile says why and does not load', () {
      final host = runner();
      addTearDown(host.dispose);

      final built = host.add(write('broken', 'this is not C++ at all'));

      expect(built.ok, isFalse);
      expect(built.output, isNotEmpty);
      expect(built.command, contains('broken.cpp'));
      expect(world.entityCount, 0);
    });

    test('a broken build leaves the working version running', () {
      final host = runner();
      addTearDown(host.dispose);
      final source = write('counter', counter);
      host.add(source);
      host.step(1);

      source.writeAsStringSync('still not C++');
      expect(host.add(source).ok, isFalse);

      host.step(1);
      expect(rows('Ticks')[1], 2);
    });

    test('it stays listed with what the compiler said about it', () {
      final host = runner();
      addTearDown(host.dispose);
      host.add(write('broken', 'nope'));

      final listed = host.scripts.single;
      expect(listed.name, 'broken');
      expect(listed.running, isFalse);
      expect(listed.output, isNotEmpty);
    });
  });

  group('rebuilding', () {
    test('new code replaces old code', () {
      final host = runner();
      addTearDown(host.dispose);
      final source = write('counter', counter);
      host.add(source);
      host.step(1);

      source.writeAsStringSync(
        counter.replaceAll('held->calls += 1.0;', 'held->calls += 10.0;'),
      );
      expect(host.add(source).ok, isTrue);

      host.step(1);

      // Two entities: the rebuilt script started again rather than resuming,
      // and only the new one's rows came from the new code.
      final ticks = rows('Ticks');
      expect(world.entityCount, 2);
      expect(ticks[1], 1, reason: 'the first script stopped being stepped');
      expect(ticks[3], 10, reason: 'the second counts by ten');
    });

    test('every build goes to a library of its own', () {
      final host = runner();
      addTearDown(host.dispose);
      final source = write('counter', counter);
      host.add(source);
      host.add(source);
      host.add(source);

      // dart:ffi cannot close a library, so reusing one path would go on
      // running the first build's code.
      final built = Directory('${root.path}/build')
          .listSync()
          .where((entry) => entry.path.endsWith(Toolchain.librarySuffix));
      expect(built, hasLength(3));
      expect(host.scripts.single.revision, 2);
    });

    test('the old one is stopped, once', () {
      final host = runner();
      addTearDown(host.dispose);
      final source = write('counter', counter);
      host.add(source);
      host.add(source);

      expect(said.where((line) => line == 'counter: stopped'), hasLength(1));
    });

    test('saving the source rebuilds it', () async {
      final host = runner();
      addTearDown(host.dispose);
      final source = write('counter', counter);
      host.add(source);

      final rebuilt = Completer<BuildResult>();
      host.watch(source, onBuilt: rebuilt.complete);

      source.writeAsStringSync(
        counter.replaceAll('held->calls += 1.0;', 'held->calls += 3.0;'),
      );

      final built = await rebuilt.future.timeout(const Duration(seconds: 30));
      expect(built.ok, isTrue, reason: built.output);

      host.step(1);
      expect(rows('Ticks')[3], 3);
    });
  });

  group('the contract', () {
    test('a library that is not a script is refused by name', () {
      final host = runner();
      addTearDown(host.dispose);

      // Compiles perfectly well; simply is not one of ours.
      final built = host.add(
        write('stranger', 'extern "C" int nothing() { return 1; }'),
      );

      expect(built.ok, isFalse);
      expect(built.output, contains('orbis_script_abi'));
    });

    test('a script built against another contract is refused, not called', () {
      final host = runner();
      addTearDown(host.dispose);

      final built = host.add(write('ancient', '''
#include "orbis_script.h"
extern "C" uint32_t orbis_script_abi(void) { return 99; }
extern "C" void orbis_start(const OrbisScriptHost *h) { (void)h; }
extern "C" void orbis_step(double d) { (void)d; }
extern "C" void orbis_stop(void) {}
'''));

      expect(built.ok, isFalse);
      expect(built.output, contains('99'));
      expect(built.output, contains('Rebuild'));
    });

    test('the header and the Dart struct agree about the table', () {
      final host = runner();
      addTearDown(host.dispose);

      // Checked by the compiler rather than asserted in Dart: C++ is the side
      // that has to agree, and a static_assert fails the build.
      final built = host.add(write('sizes', '''
#include "orbis_script.h"
static_assert(sizeof(OrbisScriptHost) == ${sizeOf<OrbisScriptHost>()},
              "the host table and the Dart struct have drifted apart");
ORBIS_SCRIPT {}
extern "C" void orbis_step(double d) { (void)d; }
extern "C" void orbis_stop(void) {}
'''));

      expect(built.ok, isTrue, reason: built.output);
    });

    test('the example in the package is a script that builds', () {
      final host = runner();
      addTearDown(host.dispose);

      final built = host.add(File('example/spinner.cpp'));
      expect(built.ok, isTrue, reason: built.output);
      expect(said, contains('spinner: started'));
    });
  });

  group('values', () {
    test('a script reads what the embedder supplies', () {
      final host = runner(
        values: _Values(
          {'ball.odata/speed': 12.5},
          {'ball.odata/bouncy': true},
          {'ball.odata/label': 'Ball'},
        ),
      );
      addTearDown(host.dispose);
      host.add(write('reader', reader));
      host.step(0.016);

      final speed = rows('Speed');
      expect(speed[0], 12.5);
      expect(speed[1], 1);
      expect(said, contains('Ball'));
    });

    test('a value that is not there falls back to what the script asked for',
        () {
      final host = runner(values: _Values());
      addTearDown(host.dispose);
      host.add(write('reader', reader));
      host.step(0.016);

      expect(rows('Speed')[0], -1.0);
    });

    test('changing one reaches the next frame', () {
      final numbers = {'ball.odata/speed': 1.0};
      final host = runner(values: _Values(numbers));
      addTearDown(host.dispose);
      host.add(write('reader', reader));

      host.step(0.016);
      numbers['ball.odata/speed'] = 9.0;
      host.step(0.016);

      // Read every frame rather than copied at start, which is what makes the
      // value a shared file rather than a constant in the source.
      expect(rows('Speed')[0], 9.0);
    });

    test('a missing text is a null pointer, not an empty string', () {
      final host = runner(values: _Values({'ball.odata/speed': 1.0}));
      addTearDown(host.dispose);
      host.add(write('reader', reader));
      host.step(0.016);

      // The script only logs when the pointer is non-null.
      expect(said, isEmpty);
    });
  });
}
