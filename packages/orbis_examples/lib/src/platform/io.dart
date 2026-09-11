// `dart:io`, where there is one.
//
// Seven examples read a file or an environment variable: a glTF scene off
// disk, a film named on the way in, a checker map painted into the temporary
// directory and handed to the renderer as a path. None of that exists in a
// browser, and `dart:io` cannot even be imported for a web target — which,
// because `engineExamples()` builds all thirty-two examples eagerly, is
// enough on its own to stop the whole gallery compiling for the web.
//
// So the import moves behind this one line. On every platform that has
// `dart:io` this is `export 'dart:io'` and nothing else, so those seven files
// are compiled against exactly what they were before, down to the type
// identity of `File`. On the web they get the stand-ins in io_web.dart, which
// answer "there is no such file" rather than refusing to build.
export 'io_native.dart' if (dart.library.js_interop) 'io_web.dart';
