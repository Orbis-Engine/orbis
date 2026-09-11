// The platform-view type the web plugin registers its canvas under.
//
// Its own file, with no imports at all, because both halves need it: the web
// plugin registers a view factory against it, and `orbis_view.dart` names it
// when it builds an `HtmlElementView` — and `orbis_view.dart` is compiled for
// every platform, so it cannot reach into `lib/src/web/`.
library;

/// What `HtmlElementView(viewType:)` and `registerViewFactory` agree on.
const String orbisWebViewType = 'dev.orbis.filament/view';
