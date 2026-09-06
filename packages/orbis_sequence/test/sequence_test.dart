import 'package:orbis_sequence/orbis_sequence.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

Clip clipOf(double start, double duration,
        {double easeIn = 0, double easeOut = 0}) =>
    Clip(start: start, duration: duration, easeIn: easeIn, easeOut: easeOut);

PropertyTrack<double> numbersOn(
  String binding,
  String property,
  List<Keyed<double>> clips,
) =>
    PropertyTrack<double>(
      binding: binding,
      property: property,
      clips: clips,
      mixer: doubleMixer,
    );

void main() {
  group('channels', () {
    test('do not extrapolate past their ends', () {
      final channel = Channel<double>(
        [const Key(1, 10.0), const Key(2, 20.0)],
        doubleMixer,
      );
      expect(channel.at(0), 10, reason: 'held before the first key');
      expect(channel.at(3), 20, reason: 'held after the last');
      expect(channel.at(1.5), closeTo(15, 1e-9),
          reason: 'the smooth default is symmetric at the middle');
    });

    test('a step key holds until the next one', () {
      final channel = Channel<double>(
        [const Key(0, 1.0, hold: Hold.step), const Key(1, 9.0)],
        doubleMixer,
      );
      expect(channel.at(0.99), 1);
      expect(channel.at(1), 9);
    });

    test('two keys at the same moment are a cut', () {
      final channel = Channel<double>(
        [const Key(0, 0.0), const Key(1, 1.0), const Key(1, 5.0)],
        doubleMixer,
      );
      expect(channel.at(1), 5);
    });

    test('rotations go the short way round', () {
      final from = Quaternion.axisAngle(Vector3(0, 1, 0), 0.1);
      final to = Quaternion.axisAngle(Vector3(0, 1, 0), -0.1);
      // Negated, which is the same rotation written the other way. Without a
      // sign check the blend takes the long way and swings all the way round.
      final flipped = Quaternion(-to.x, -to.y, -to.z, -to.w);
      final middle = quaternionMixer.lerp(from, flipped, 0.5);
      expect(middle.y.abs(), lessThan(1e-6),
          reason: 'halfway between +0.1 and -0.1 about Y is no turn at all');
      expect(middle.w.abs(), closeTo(1, 1e-6));
    });

    test('a binary search finds the right span in a long channel', () {
      final keys = [
        for (var i = 0; i < 200; i++) Key(i.toDouble(), i * 2.0, hold: Hold.linear)
      ];
      final channel = Channel<double>(keys, doubleMixer);
      expect(channel.at(150.5), closeTo(301, 1e-9));
    });
  });

  group('clips', () {
    test('weight fades in and out and holds between', () {
      final clip = clipOf(0, 10, easeIn: 2, easeOut: 2);
      expect(clip.weightAt(-1), 0);
      expect(clip.weightAt(0), 0);
      expect(clip.weightAt(1), closeTo(ease(Easing.inOut, 0.5), 1e-9));
      expect(clip.weightAt(5), 1);
      expect(clip.weightAt(9), closeTo(ease(Easing.inOut, 0.5), 1e-9));
      expect(clip.weightAt(10), 0, reason: 'the end is exclusive');
    });

    test('trimming and speed change where the content is read', () {
      const clip = Clip(start: 10, duration: 4, clipIn: 2, speed: 2);
      expect(clip.localAt(10), 2, reason: 'starts two seconds in');
      expect(clip.localAt(11), 4, reason: 'and runs at double');
    });

    test('a clip in the middle of a fade counts for less than one', () {
      final clip = clipOf(0, 4, easeOut: 4);
      expect(clip.weightAt(2), closeTo(0.5, 1e-9));
    });
  });

  group('property tracks', () {
    test('say nothing where no clip covers', () {
      final track = numbersOn('crate', 'height', [
        Keyed(clipOf(2, 2), Channel<double>([const Key(0, 5.0)], doubleMixer)),
      ]);
      expect(track.valueAt(0), isNull, reason: 'before its clip');
      expect(track.valueAt(3), 5);
      expect(track.valueAt(5), isNull, reason: 'after it');
    });

    test('two overlapping clips blend by weight', () {
      final track = numbersOn('crate', 'height', [
        Keyed(clipOf(0, 4, easeOut: 2),
            Channel<double>([const Key(0, 0.0)], doubleMixer)),
        Keyed(clipOf(2, 4, easeIn: 2),
            Channel<double>([const Key(0, 10.0)], doubleMixer)),
      ]);
      // At the exact middle of the overlap both are at half weight, so the
      // answer is halfway between what each of them wanted.
      expect(track.valueAt(3), closeTo(5, 1e-9));
      expect(track.valueAt(1), 0, reason: 'only the first has anything to say');
      expect(track.valueAt(5), 10);
    });

    test('a muted track contributes nothing', () {
      final track = PropertyTrack<double>(
        binding: 'crate',
        property: 'height',
        muted: true,
        mixer: doubleMixer,
        clips: [
          Keyed(clipOf(0, 4), Channel<double>([const Key(0, 5.0)], doubleMixer))
        ],
      );
      final frame = SequenceFrame(1);
      track.contribute(1, frame);
      expect(frame.values, isEmpty);
    });

    test('positions blend as positions', () {
      final track = PropertyTrack<Vector3>(
        binding: 'crate',
        property: 'position',
        mixer: vector3Mixer,
        clips: [
          Keyed(
            clipOf(0, 2),
            Channel<Vector3>([
              Key(0, Vector3(0, 0, 0), hold: Hold.linear),
              Key(2, Vector3(10, 0, 0)),
            ], vector3Mixer),
          ),
        ],
      );
      expect(track.valueAt(1)!.x, closeTo(5, 1e-9));
    });
  });

  group('activation', () {
    test('says off in the gaps and nothing outside its span', () {
      const track = ActivationTrack(binding: 'door', clips: [
        Clip(start: 1, duration: 1),
        Clip(start: 3, duration: 1),
      ]);
      expect(track.contributionAt(0), isNull, reason: 'before it starts');
      expect(track.contributionAt(1.5), isTrue);
      expect(track.contributionAt(2.5), isFalse, reason: 'in the gap');
      expect(track.contributionAt(3.5), isTrue);
      expect(track.contributionAt(9), isNull, reason: 'after it ends');
    });
  });

  group('marks', () {
    test('fire on the way forwards and never on the way back', () {
      const sequence = Sequence(tracks: [
        MarkTrack(marks: [Mark(1, 'open'), Mark(2, 'shut')]),
      ], duration: 5);

      expect(sequence.marksBetween(0, 3).map((one) => one.name),
          ['open', 'shut']);
      expect(sequence.marksBetween(3, 0), isEmpty);
      expect(sequence.marksBetween(1, 2).map((one) => one.name), ['shut'],
          reason: 'the start of a span is exclusive, so nothing fires twice');
    });

    test('a step big enough to skip several fires all of them', () {
      const sequence = Sequence(tracks: [
        MarkTrack(marks: [
          Mark(0.1, 'a'),
          Mark(0.2, 'b'),
          Mark(0.3, 'c'),
        ]),
      ], duration: 1);
      expect(sequence.marksBetween(0, 0.9).length, 3);
    });
  });

  group('the director', () {
    Sequence sequenceOf() => Sequence(
          duration: 4,
          tracks: [
            numbersOn('crate', 'height', [
              Keyed(
                clipOf(0, 4),
                Channel<double>([
                  const Key(0, 0.0, hold: Hold.linear),
                  const Key(4, 4.0),
                ], doubleMixer),
              ),
            ]),
            const MarkTrack(marks: [Mark(1, 'ping'), Mark(3, 'pong')]),
          ],
        );

    test('does not move while paused', () {
      final director = Director(sequenceOf());
      final step = director.advance(1);
      expect(director.at, 0);
      expect(step.marks, isEmpty);
      expect(step.frame.get('crate', 'height'), 0);
    });

    test('fires each mark once as it passes', () {
      final director = Director(sequenceOf())..play();
      expect(director.advance(0.5).marks, isEmpty);
      expect(director.advance(1).marks.map((one) => one.name), ['ping']);
      expect(director.advance(1).marks, isEmpty);
      expect(director.advance(1).marks.map((one) => one.name), ['pong']);
    });

    test('holding stops on the last frame', () {
      final director = Director(sequenceOf())..play();
      director.advance(10);
      expect(director.at, 4);
      expect(director.playing, isFalse);
      expect(director.finished, isTrue);
    });

    test('looping wraps and fires the marks it crosses on the way round', () {
      final director = Director(sequenceOf(), whenDone: WhenDone.loop)..play();
      expect(director.advance(3.5).marks.map((one) => one.name),
          ['ping', 'pong'], reason: 'both, in order, in one step');
      final wrapped = director.advance(1.5);
      expect(director.at, closeTo(1, 1e-9));
      expect(wrapped.marks.map((one) => one.name), ['ping'],
          reason: 'nothing left this pass, then the first of the next');
      expect(director.playing, isTrue);
    });

    test('bouncing turns round rather than stopping', () {
      final director = Director(sequenceOf(), whenDone: WhenDone.bounce)..play();
      director.advance(5);
      expect(director.at, closeTo(3, 1e-9));
      expect(director.playing, isTrue);
      director.advance(1);
      expect(director.at, closeTo(2, 1e-9), reason: 'still going backwards');
    });

    test('seeking moves the playhead and fires nothing', () {
      final director = Director(sequenceOf())..play();
      director.seek(3.5);
      expect(director.at, 3.5);
      expect(director.sample().get('crate', 'height'), closeTo(3.5, 1e-9));
      // Advancing from there crosses no mark, because seeking already passed
      // them and passing them by looking is not passing them.
      expect(director.advance(0.1).marks, isEmpty);
    });

    test('seeking is clamped to the sequence', () {
      final director = Director(sequenceOf());
      director.seek(-5);
      expect(director.at, 0);
      director.seek(500);
      expect(director.at, 4);
    });

    test('scrubbing backwards gives the same values as playing forwards', () {
      final sequence = sequenceOf();
      final forwards = [
        for (var i = 0; i <= 40; i++) sequence.sampleAt(i / 10).get('crate', 'height')
      ];
      final backwards = [
        for (var i = 40; i >= 0; i--) sequence.sampleAt(i / 10).get('crate', 'height')
      ].reversed.toList();
      expect(forwards, backwards);
    });
  });

  group('shots and sounds', () {
    test('adjacent shots are a cut and overlapping ones a blend', () {
      const track = ShotTrack(shots: [
        (Clip(start: 0, duration: 2), 'wide'),
        (Clip(start: 2, duration: 2), 'close'),
      ]);
      final cut = SequenceFrame(1.9);
      track.contribute(1.9, cut);
      expect(cut.shots.map((one) => one.camera), ['wide']);

      const blended = ShotTrack(shots: [
        (Clip(start: 0, duration: 3, easeOut: 1), 'wide'),
        (Clip(start: 2, duration: 3, easeIn: 1), 'close'),
      ]);
      final over = SequenceFrame(2.5);
      blended.contribute(2.5, over);
      expect(over.shots.length, 2);
      expect(over.shots.first.weight, closeTo(over.shots.last.weight, 1e-9));
    });

    test('a sound reports where in itself the playhead is', () {
      const track = SoundTrack(clips: [
        (Clip(start: 4, duration: 3, clipIn: 1), 'thunder.wav'),
      ]);
      final frame = SequenceFrame(5);
      track.contribute(5, frame);
      expect(frame.sounds.single.sound, 'thunder.wav');
      expect(frame.sounds.single.at, 2, reason: 'one second of trim, one played');
    });
  });

  test('a sequence is as long as its longest track unless told otherwise', () {
    final tracks = [
      numbersOn('a', 'x', [
        Keyed(clipOf(0, 2), Channel<double>([const Key(0, 0.0)], doubleMixer))
      ]),
      numbersOn('b', 'x', [
        Keyed(clipOf(0, 7), Channel<double>([const Key(0, 0.0)], doubleMixer))
      ]),
    ];
    expect(Sequence(tracks: tracks).duration, 7);
    expect(Sequence(tracks: tracks, duration: 20).duration, 20);
  });

  test('snapping lands on a frame boundary', () {
    const sequence = Sequence(tracks: [], rate: 24);
    expect(sequence.snap(0.5), closeTo(12 / 24, 1e-9));
    expect(sequence.snap(0.501), closeTo(12 / 24, 1e-9));
  });
}
