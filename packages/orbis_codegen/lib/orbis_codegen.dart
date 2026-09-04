/// Turns annotated component classes into registration code and a manifest.
library;

export 'annotations.dart' show OrbisComponent, OrbisKind;
export 'src/emitter.dart' show ComponentEmitter;
export 'src/model.dart' show ComponentDeclaration, ComponentError, ScanResult;
export 'src/scanner.dart' show ComponentScanner;
