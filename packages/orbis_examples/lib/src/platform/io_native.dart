// The real thing, on every platform that has it.
//
// Deliberately nothing but a re-export: the seven examples behind
// platform/io.dart must compile against the genuine `dart:io` — the same
// `File`, the same `Directory`, the same `Platform` — so that macOS, iOS and
// Android behave exactly as they did before the web split existed.
export 'dart:io';
