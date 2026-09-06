/// Cutscenes as a function of time.
///
/// A sequence is tracks of clips over a playhead, and sampling it at a moment
/// gives everything it has to say at that moment. Nothing is remembered
/// between samples, so scrubbing backwards, replaying a recorded time and
/// stepping frame by frame all come out the same — which is what makes a
/// cutscene something an editor can work on rather than only play.
///
/// The exception is marks, which are about an interval rather than a point:
/// they come out of advancing a [Director], never out of a sample, so looking
/// at a moment cannot make the scene happen.
library;

export 'src/channel.dart'
    show
        BoolMixer,
        Channel,
        DoubleMixer,
        Hold,
        Key,
        Mixer,
        QuaternionMixer,
        Vector3Mixer,
        boolMixer,
        doubleMixer,
        quaternionMixer,
        vector3Mixer;
export 'src/clip.dart' show Clip;
export 'src/director.dart' show Advanced, Director, WhenDone;
export 'src/easing.dart' show Easing, ease;
export 'src/sequence.dart' show Sequence;
export 'src/track.dart'
    show
        ActivationTrack,
        Keyed,
        Mark,
        MarkTrack,
        PropertyTrack,
        SequenceFrame,
        ShotAt,
        ShotTrack,
        SoundAt,
        SoundTrack,
        Track;
