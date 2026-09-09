/// Runs one worked example, full window, so a frame of it can be looked at.
///
/// The examples are shown inside the editor, which opens on a project list —
/// so nothing draws there until somebody clicks, and neither a frame smoke nor
/// a person trying to reproduce a rendering fault can get at them. This opens
/// straight into a scene.
///
/// Driven by the environment, so a sweep of camera angles is a shell loop
/// rather than a person dragging:
///
///   ORBIS_EXAMPLE=Blocks   which one, by name (default: the first)
///   ORBIS_YAW / ORBIS_PITCH / ORBIS_DISTANCE   where to look from
///   ORBIS_SECONDS          hold the clock still, for a scene that animates
///   ORBIS_WALK=0           give the camera back, for an example that drives it
///   ORBIS_RANGE            how far a population is drawn from; 0 draws it all
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:orbis_examples/orbis_examples.dart';
import 'package:orbis_filament/orbis_filament.dart';

void main() => runApp(const Gallery());

double? _number(String name) =>
    double.tryParse(Platform.environment[name] ?? '');

class Gallery extends StatelessWidget {
  const Gallery({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Orbis Gallery',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const _Stage(),
  );
}

class _Stage extends StatefulWidget {
  const _Stage();

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> with SingleTickerProviderStateMixin {
  late final List<Example> _all = engineExamples();
  late final Example _example = _chosen();
  late final GalleryCamera _look = GalleryCamera.from(_example.viewpoint);
  late final Ticker _clock;

  double _seconds = 0;

  Example _chosen() {
    final wanted = Platform.environment['ORBIS_EXAMPLE'];
    if (wanted == null || wanted.isEmpty) return _all.first;
    return _all.firstWhere(
      (one) => one.name.toLowerCase() == wanted.toLowerCase(),
      orElse: () {
        stderr.writeln(
          'no example called "$wanted" — there is '
          '${_all.map((e) => e.name).join(', ')}',
        );
        return _all.first;
      },
    );
  }

  @override
  void initState() {
    super.initState();

    // An example that puts somebody inside it drives the camera itself, which
    // is right for playing and useless for looking at a particular corner of
    // it. This hands the camera back.
    final example = _example;
    if (example is VoxelExample) {
      if (Platform.environment['ORBIS_WALK'] == '0') example.walking = false;
      final far = _number('ORBIS_RANGE');
      if (far != null) example.range = far;
    }

    _look.yaw = _number('ORBIS_YAW') ?? _look.yaw;
    _look.pitch = _number('ORBIS_PITCH') ?? _look.pitch;
    _look.distance = _number('ORBIS_DISTANCE') ?? _look.distance;

    // A fixed clock when one is asked for, so two runs of an animating scene
    // are the same picture and can be compared.
    final held = _number('ORBIS_SECONDS');
    if (held != null) {
      _seconds = held;
      _clock = Ticker((_) => setState(() {}))..start();
    } else {
      _clock = Ticker((elapsed) {
        setState(() => _seconds = elapsed.inMicroseconds / 1e6);
      })..start();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: GestureDetector(
      onPanUpdate: (details) => setState(() => _look.orbit(details.delta)),
      child: OrbisView(scene: _example.scene(_look.toRenderCamera(), _seconds)),
    ),
  );
}
