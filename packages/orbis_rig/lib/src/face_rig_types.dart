import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'collections.dart';
import 'constraints.dart';
import 'naming.dart';
import 'rig_type.dart';
import 'widgets.dart';

/// The collection every face control goes in, so the whole face can be hidden
/// while a body is animated — which is most of the time.
const faceCollection = 'Face';

/// The deform bone for a source bone, shadowing an original.
///
/// The same ending as every other rig type: the mesh binds to bones that copy
/// something, so the something can be rebuilt without the mesh noticing.
String _deform(
  RigContext context,
  String sourceName,
  String organic, {
  String? parent,
}) {
  final deform = context.copy(
    sourceName,
    role: BoneRole.deform,
    parent: parent,
  );
  context.constrain(deform, CopyTransform(organic));
  return deform;
}

/// A jaw: one control that opens, and cannot open backwards.
///
/// A hinge rather than a free joint. The limit is the whole reason this is not
/// a plain copy — a jaw with no limit turns inside the skull the first time an
/// animator overshoots, and it is not obvious from the curve that they did.
class JawRig implements RigType {
  /// [maximumAngle] is how far the jaw may turn from its rest, in radians.
  const JawRig({this.maximumAngle = math.pi / 5});

  final double maximumAngle;

  @override
  String get id => 'face.jaw';

  @override
  int get minimumBones => 1;

  @override
  void generate(RigContext context, List<String> chain) {
    final sourceName = chain.first;

    final organic = context.copy(sourceName, role: BoneRole.original);
    final control = context.copy(sourceName);

    context
      ..constrain(organic, CopyTransform(control))
      ..constrain(organic, LimitRotation(maximumAngle: maximumAngle))
      ..widget(control, const BoneWidget(shape: WidgetShape.circle, size: 1.3))
      ..collect(control, faceCollection, colour: BoneCollections.centreColour);

    _deform(context, sourceName, organic);
  }
}

/// An eye: a target out in front that it looks at.
///
/// Eyes are aimed, not rotated. Nobody animates an eyeball by turning it —
/// they move the thing it is looking at.
///
/// Each eye has its own target, and the targets hang off one shared control so
/// a character can look somewhere in a single move. Every eye also gets a
/// second aim at the shared control itself, blended in by [focusProperty]:
///
/// * At zero the eyes stay parallel, each looking exactly where the modeller
///   pointed it. This has to be the default, because a rig with nothing posed
///   must reproduce the rest pose — anything else changes the neutral the mesh
///   was built in.
/// * At one both eyes aim at the same point, so they converge. That is what
///   makes a character appear to be looking at something near rather than
///   staring through it.
///
/// The shared control is created once however many eyes ask for it, and sits
/// midway between them, so the second eye joins the first rather than getting
/// a control of its own.
class EyeRig implements RigType {
  /// [distance] is how far in front of the eye the target sits, in bone
  /// lengths. Far enough that moving it turns the eye by a usable amount, near
  /// enough that it stays on screen.
  const EyeRig({this.distance = 8});

  final double distance;

  /// What the shared look-at control is called.
  static const masterName = 'eyes';

  /// The value that crosses the eyes from parallel onto a single point.
  static const focusProperty = 'eyes_focus';

  @override
  String get id => 'face.eye';

  @override
  int get minimumBones => 1;

  @override
  void generate(RigContext context, List<String> chain) {
    final sourceName = chain.first;
    final side = BoneNaming.sideOf(sourceName);
    final base = BoneNaming.baseOf(sourceName);

    final eye = context.source[sourceName]!;
    final ahead = eye.head + eye.direction * (eye.length * distance);

    // Midway between the two eyes, worked out from the mirrored bone rather
    // than by assuming which axis the body is symmetrical about. A single or
    // central eye simply uses its own.
    final mirror = BoneNaming.mirror(sourceName);
    final other = mirror == null ? null : context.source[mirror];
    final centre = other == null
        ? ahead
        : (ahead + other.head + other.direction * (other.length * distance))
              .scaled(0.5);

    // One control both eyes hang off, so a character can look somewhere in one
    // move rather than two that have to agree.
    final master = context.createShared(
      masterName,
      head: centre,
      tail: centre + Vector3(0, eye.length, 0),
    );

    // Each eye keeps its own target under the shared one, sitting exactly on
    // the eye's own axis so that an unposed rig reproduces the rest pose.
    final target = context.create(
      BoneNaming.compose('${base}_target', side: side),
      head: ahead,
      tail: ahead + Vector3(0, eye.length * 0.5, 0),
      role: BoneRole.control,
      parent: master,
    );

    context.property(focusProperty, 0);

    final organic = context.copy(sourceName, role: BoneRole.original);
    // Two aims reading one number, one of them inverted — the same shape as a
    // limb's inverse-forward switch. At zero the eye follows its own target
    // and the pair stay parallel; at one both follow the shared control and
    // converge on it.
    context
      ..constrain(
        organic,
        DampedTrack(
          target: target,
          influenceProperty: focusProperty,
          invertInfluence: true,
        ),
      )
      ..constrain(
        organic,
        DampedTrack(target: master, influenceProperty: focusProperty),
      );

    _deform(context, sourceName, organic);

    context
      ..widget(master, const BoneWidget(shape: WidgetShape.square, size: 4))
      ..widget(target, const BoneWidget(shape: WidgetShape.circle, size: 1.5))
      ..collect(master, faceCollection, colour: BoneCollections.centreColour)
      ..collect(
        target,
        faceCollection,
        colour: BoneCollections.colourFor(side),
      );
  }
}

/// An eyelid: follows the eye part of the way, and closes on its own.
///
/// A lid that ignored the eye would slide off the eyeball as it turned, and
/// one that followed it exactly would never blink independently. Partial
/// following plus its own control is what a lid actually does.
class EyelidRig implements RigType {
  /// [follow] is how much of the eye's rotation the lid takes, from zero to
  /// one. Around a third is the usual answer: enough that the lid stays with
  /// the eye, little enough that looking down does not close it.
  const EyelidRig({required this.eye, this.follow = 0.35});

  /// The bone in the meta-rig this lid belongs to. Named rather than guessed,
  /// because an upper and a lower lid sit either side of the same eye and
  /// nothing in the skeleton says which eye that is.
  final String eye;

  final double follow;

  @override
  String get id => 'face.eyelid';

  @override
  int get minimumBones => 1;

  @override
  void generate(RigContext context, List<String> chain) {
    final sourceName = chain.first;
    final side = BoneNaming.sideOf(sourceName);

    final organic = context.copy(sourceName, role: BoneRole.original);
    final control = context.copy(sourceName);

    context.constrain(organic, CopyTransform(control));

    // Checked against the meta-rig, not the generated one. The eye may not
    // have been generated yet — assignments run in name order — and testing
    // the output would make this lid silently stop following depending on what
    // the eye happened to be called.
    if (!context.source.contains(eye)) {
      context.problem(
        sourceName,
        'follows an eye called "$eye", which is not in the meta-rig',
      );
    } else {
      // The eye's original, which is where the aiming ended up. Following the
      // control instead would miss everything the look-at target did.
      context.constrain(
        organic,
        CopyRotation(
          BoneNaming.asRole(eye, BoneRole.original),
          influence: follow.clamp(0.0, 1.0),
        ),
      );
    }

    _deform(context, sourceName, organic);

    context
      ..widget(control, const BoneWidget(shape: WidgetShape.circle, size: 0.9))
      ..collect(
        control,
        faceCollection,
        colour: BoneCollections.colourFor(side),
      );
  }
}
