import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// Builds the core into one library the Dart bindings open over FFI.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final root = input.packageRoot;
    final builder = CBuilder.library(
      name: 'orbis_core',
      assetName: 'orbis_core',
      sources: [
        root.resolve('src/world.cpp').toFilePath(),
        root.resolve('src/orbis_core.cpp').toFilePath(),
        root.resolve('src/transform.cpp').toFilePath(),
      ],
      includes: [
        root.resolve('include/').toFilePath(),
        root.resolve('src/').toFilePath(),
      ],
      language: Language.cpp,
    );

    await builder.run(input: input, output: output, logger: null);
  });
}
