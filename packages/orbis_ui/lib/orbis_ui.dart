/// The interface a game draws.
///
/// One document model with two ways in. The editor lays a canvas out visually
/// and writes a `.oui`; a script describes the same tree in TypeScript and
/// sends it. Both arrive here as a [UiNode] tree and are built into real
/// Flutter widgets — laid out by Flutter, hit-tested by Flutter, drawn by
/// Impeller — rather than into a second widget system pretending to be one.
///
/// Which way in somebody uses is a preference, not a fork: a canvas laid out
/// by hand can be handed to a script to change, and a script's tree can be
/// saved as a canvas and edited by hand. Two authoring front ends onto one
/// model, the same shape as the scripting boundary.
///
/// The styling vocabulary is borrowed on purpose. `p-4 flex-1 items-center
/// bg-slate-800 rounded-lg` means what somebody who has written a web page
/// expects, and `padding: 8px 12px; border-radius: 6px` means the same in the
/// other notation. Both resolve to Flutter's own layout, so the familiar words
/// are a way in rather than a second box model to keep aligned forever.
library;

export 'src/builder.dart' show UiBuilder, UiDecorator, UiEvent;
export 'src/css.dart' show UiCss;
export 'src/document.dart' show CanvasFit, UiCanvas, UiDocument;
export 'src/node.dart' show UiNode;
export 'src/responsive.dart' show UiBreakpoints;
export 'src/style.dart' show UiStyle;
export 'src/surface.dart' show UiSurface;
export 'src/theme.dart' show UiTheme;
export 'src/utilities.dart' show UiUtilities, parseColour;
