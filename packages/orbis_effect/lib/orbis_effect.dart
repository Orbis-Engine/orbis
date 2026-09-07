/// Change stated as a function of time.
///
/// **Sampled, not stepped.** An effect is asked what it looks like at a
/// moment rather than advanced by a frame's worth — the same choice the
/// sequencer makes, and for the same reasons: it scrubs backwards, it gives
/// the same answer at the same moment however the frames fell, and a test can
/// ask about the middle without running the beginning.
///
/// The cost is real and worth stating. An effect cannot depend on where the
/// thing currently is: `MoveBy` is expressible and "move towards whatever is
/// nearest" is not. That is steering, and it lives in `orbis_agent` on
/// purpose.
///
/// What an effect produces is a *difference* — an offset, a turn, a
/// multiplier — which is what lets two of them run at once and be added
/// together without either knowing about the other.
library;

export 'src/ease.dart' show Ease, Eases;
export 'src/effect.dart'
    show
        After,
        Again,
        Both,
        Change,
        Effect,
        FadeTo,
        GrowTo,
        MoveBy,
        OutAndBack,
        Playing,
        Shake,
        Then,
        TintTo,
        TurnBy,
        Wait,
        applied,
        lerp,
        shortestTurn;
