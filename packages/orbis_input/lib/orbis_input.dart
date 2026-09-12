/// Gamepads, as state a frame can ask about.
///
/// **Polled first, with events alongside.** Most of this engine is sampled
/// rather than stepped — an effect is asked what it looks like at a moment, a
/// sequence is asked what it says at a moment — and input is the one thing
/// that cannot be. A pad is not a function of time; it is the outside world
/// arriving, and the only honest way to read it is to drain what has happened
/// since the last time anybody looked.
///
/// So this takes the shape of the one stateful thing the rest of the engine
/// already has: [Pads.poll] answers like `Director.advance` does, with where
/// things now stand *and* what happened getting there. A game loop asks "is
/// this button down" and "did it go down this frame" of the state, and reads
/// the events for the two things a snapshot genuinely cannot hold — a button
/// pressed and released between two polls, and a pad arriving or leaving.
///
/// An events-only API would make every caller keep that state themselves, and
/// every one of them would keep it slightly differently. A state-only API
/// would silently lose the quick tap and have nowhere to put a hot-plug.
///
/// What is deliberately here rather than in each game: dead zones, response
/// curves and layouts. Those are the three things every game gets wrong in the
/// same way, and an engine that leaves them out has not finished the job.
library;

export 'src/backend.dart'
    show PadBackend, PadDevice, RecordedPad, RecordedPads, noPads;
export 'src/evdev.dart'
    show
        EvdevCapabilities,
        EvdevDecoder,
        EvdevEvent,
        encodeEvdevEvent,
        evAbs,
        evKey,
        evSyn,
        synDropped,
        synReport;
export 'src/layout.dart' show PadAxisRange, PadLayout, PadLabels;
export 'src/linux.dart' show LinuxPads;
export 'src/pad.dart'
    show PadAxis, PadButton, PadIdentity, PadSide, PadState, PadStick;
export 'src/pads.dart'
    show
        PadConnected,
        PadDisconnected,
        PadEvent,
        PadFrame,
        PadPressed,
        PadReleased,
        Pads;
export 'src/shaping.dart' show Shaping;
