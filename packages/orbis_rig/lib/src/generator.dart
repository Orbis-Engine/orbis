import 'armature.dart';
import 'rig_type.dart';

/// A skeleton, marked up with what each part should become.
///
/// The thing an artist actually builds: a plain armature roughly the shape of
/// the character, with a note on each chain saying "this is an arm". Everything
/// else is generated from it, which means a rig can be thrown away and rebuilt
/// after the skeleton changes rather than being repaired by hand.
class MetaRig {
  MetaRig(this.armature);

  final Armature armature;
  final Map<String, RigType> _assignments = {};

  /// Marks the chain starting at [bone] as something.
  void assign(String bone, RigType type) => _assignments[bone] = type;

  RigType? typeOf(String bone) => _assignments[bone];

  /// Assignments in a stable order, so generating twice produces the same rig.
  List<MapEntry<String, RigType>> get assignments {
    final entries = _assignments.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }

  bool get isEmpty => _assignments.isEmpty;
}

/// Something wrong with a meta-rig, reported rather than thrown.
///
/// Collected rather than raised on the first one, because an artist fixing a
/// rig wants the whole list — finding one problem per generate is how a five
/// minute fix becomes an afternoon.
class RigProblem {
  const RigProblem(this.bone, this.message);

  final String bone;
  final String message;

  @override
  String toString() => '$bone: $message';
}

/// A rig, generated.
class GeneratedRig {
  GeneratedRig({
    required this.armature,
    required this.pose,
    required this.controls,
    required this.properties,
    required this.unassigned,
    required this.problems,
  });

  final Armature armature;
  final Pose pose;

  /// The bones an animator is meant to touch.
  final Set<String> controls;

  /// Named values with the number each starts at.
  final Map<String, double> properties;

  /// Bones in the meta-rig that no rig type claimed.
  ///
  /// Reported rather than dropped silently: a bone nobody claimed is almost
  /// always a chain somebody forgot to mark, and it is invisible in the result
  /// precisely when it matters.
  final Set<String> unassigned;

  final List<RigProblem> problems;

  bool get hasProblems => problems.isNotEmpty;

  Iterable<String> get deformBones =>
      armature.deformingBones.map((bone) => bone.name);
}

/// Turns a marked-up skeleton into a working rig.
class RigGenerator {
  const RigGenerator();

  GeneratedRig generate(MetaRig meta) {
    final output = Armature();
    final pose = Pose(output);
    final context = RigContext(
      source: meta.armature,
      output: output,
      pose: pose,
    );

    final problems = <RigProblem>[];
    final claimed = <String>{};

    for (final entry in meta.assignments) {
      final start = entry.key;
      final type = entry.value;

      if (!meta.armature.contains(start)) {
        problems.add(
          RigProblem(start, 'assigned ${type.id} but there is no such bone'),
        );
        continue;
      }

      final chain = _chainFrom(meta, start);
      if (chain.length < type.minimumBones) {
        problems.add(
          RigProblem(
            start,
            '${type.id} needs at least ${type.minimumBones} connected bones, '
            'and this chain has ${chain.length}',
          ),
        );
        continue;
      }

      claimed.addAll(chain);
      type.generate(context, chain);
    }

    final unassigned = {
      for (final bone in meta.armature.bones)
        if (!claimed.contains(bone.name)) bone.name,
    };

    return GeneratedRig(
      armature: output,
      pose: pose,
      controls: context.controls,
      properties: context.defaults,
      unassigned: unassigned,
      problems: problems,
    );
  }

  /// The run of bones one rig type owns.
  ///
  /// Follows connected children while there is exactly one, and stops at
  /// anything that has been marked as something else. That is what lets a hand
  /// be assigned separately from the arm it hangs off without either one having
  /// to name the other.
  List<String> _chainFrom(MetaRig meta, String start) {
    final chain = <String>[start];
    final seen = <String>{start};

    var current = start;
    while (true) {
      final children = meta.armature
          .childrenOf(current)
          .where((bone) => bone.connected)
          .toList();

      if (children.length != 1) break;

      final next = children.single.name;
      // A chain that loops would run forever; the armature refuses one, but a
      // generator that trusted it would be a worse place to find out.
      if (!seen.add(next)) break;
      if (meta.typeOf(next) != null) break;

      chain.add(next);
      current = next;
    }

    return chain;
  }
}
