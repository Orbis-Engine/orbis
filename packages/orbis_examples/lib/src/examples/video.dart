import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../example.dart';
import 'surface.dart' show linearOf;

/// A moving picture, in the world.
///
/// The frame never becomes a texture in the ordinary sense. It stays the
/// buffer the decoder wrote and is handed to the GPU where it lies, which is
/// the difference between a screen that costs an upload every frame and one
/// that costs about as much as a flat colour.
///
/// Which is also why the same film on four screens is one decoder and not
/// four: a video is listed on the scene, and a material points at it.
class VideoExample extends Example {
  VideoExample() {
    // A film named on the way in, for a screenshot or a test. Everybody else
    // picks one — see [settings].
    final given = Platform.environment['ORBIS_VIDEO'];
    if (given != null && File(given).existsSync()) path = given;
  }

  @override
  String get name => 'Video';

  @override
  String get blurb =>
      'A film on four screens from one decoder, tinted, faded and played '
      'backwards — set ORBIS_VIDEO or paste a path.';

  @override
  ViewPoint get viewpoint =>
      const ViewPoint(distance: 14, pitch: 0.14, yaw: 0.0);

  String? path;

  /// What went wrong with the last file somebody named, if anything.
  ///
  /// Said out loud, because a path that cannot be read and a film that has
  /// not started decoding look identical from here — four black rectangles —
  /// and the example is then indistinguishable from a renderer that does not
  /// work.
  String? trouble;

  bool playing = true;
  bool loop = true;
  double rate = 1.0;
  double fade = 1.0;
  int _seekToken = 0;
  double? _seekTo;

  late final TextEditingController _field = TextEditingController(
    text: path ?? '',
  );

  @override
  OrbisScene scene(OrbisCamera camera, double seconds) {
    final showing = path;
    final videos = <OrbisVideo>[
      if (showing != null)
        OrbisVideo(
          key: 1,
          path: showing,
          playing: playing,
          loop: loop,
          rate: rate,
          volume: 0,
          seekTo: _seekTo,
          seekToken: _seekToken,
        ),
    ];

    final materials = <OrbisMaterial>[
      // The room, so a screen has somewhere to be and something to light.
      OrbisMaterial(
        key: 1,
        baseColour: Vector4(0.16, 0.17, 0.20, 1),
        roughness: 0.9,
      ),
      // Four screens, all pointing at the same film. The tints are the point:
      // the base colour multiplies the frame, so a screen can be dimmed,
      // washed or faded without the decoder knowing anything about it.
      for (var i = 0; i < 4; i++)
        OrbisMaterial(
          key: 10 + i,
          shading: OrbisShading.video,
          video: 1,
          blend: i == 3 ? OrbisBlend.fade : OrbisBlend.opaque,
          baseColour: switch (i) {
            0 => Vector4(1, 1, 1, 1),
            1 => Vector4(1.0, 0.55, 0.35, 1),
            2 => Vector4(0.45, 0.70, 1.0, 1),
            _ => Vector4(1, 1, 1, fade),
          },
        ),
    ];

    final objects = <OrbisObject>[
      OrbisObject(
        key: 1,
        material: 1,
        transform: Matrix4.identity()
          ..setTranslation(Vector3(0, -2.6, 0))
          ..multiply(Matrix4.diagonal3(Vector3(14, 0.05, 10))),
        colour: linearOf(const Color(0xFF2A2E35)),
      ),
      for (var i = 0; i < 4; i++)
        OrbisObject(
          key: 10 + i,
          material: 10 + i,
          transform: Matrix4.identity()
            ..setTranslation(Vector3((i - 1.5) * 4.0, 0, 0))
            // Sixteen by nine, and thin: a screen is a plane with a back to
            // it, which is why the material is double-sided by nothing and
            // the box has depth instead.
            ..multiply(Matrix4.diagonal3(Vector3(1.78, 1.0, 0.06))),
          colour: Vector3(1, 1, 1),
        ),
    ];

    return OrbisScene(
      objects: objects,
      materials: materials,
      videos: videos,
      camera: camera,
      lights: [
        OrbisLight(
          key: 900,
          kind: OrbisLightKind.directional,
          direction: Vector3(-0.3, -1, -0.5),
          intensity: 24000,
        ),
      ],
      sky: OrbisSky(colour: Vector3(0.05, 0.06, 0.08), ambient: 6000),
      post: OrbisPostProcess(bloom: OrbisBloom(enabled: true, strength: 0.14)),
    );
  }

  @override
  Widget settings(BuildContext context, VoidCallback changed) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.movie_outlined, size: 16),
            label: Text(path == null ? 'Choose a film…' : 'Choose another…'),
            onPressed: () async {
              // Picked rather than typed. A path somebody types is a guess,
              // and this example spent its life showing four black
              // rectangles because the guess was usually wrong and nothing
              // said so.
              final file = await openFile(
                acceptedTypeGroups: const [
                  XTypeGroup(label: 'Video', extensions: ['mp4', 'mov', 'm4v']),
                ],
              );
              if (file == null) return;
              path = file.path;
              trouble = null;
              _field.text = file.path;
              changed();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: _field,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Or a path',
              hintText: '/path/to/a.mp4',
            ),
            onSubmitted: (value) {
              final wanted = value.trim();
              if (wanted.isEmpty) {
                path = null;
                trouble = null;
              } else if (!File(wanted).existsSync()) {
                // Checked here rather than left to the decoder, which reports
                // nothing back and simply shows no frames.
                trouble = 'There is no file at that path.';
              } else {
                path = wanted;
                trouble = null;
              }
              changed();
            },
          ),
        ),
        Toggle(
          label: 'Playing',
          value: playing,
          onChanged: (value) {
            playing = value;
            changed();
          },
        ),
        Toggle(
          label: 'Loop',
          value: loop,
          onChanged: (value) {
            loop = value;
            changed();
          },
        ),
        Setting(
          label: 'Rate',
          value: rate,
          min: -2,
          max: 3,
          decimals: 2,
          onChanged: (value) {
            rate = value;
            changed();
          },
        ),
        Setting(
          label: 'Fade',
          value: fade,
          min: 0,
          max: 1,
          decimals: 2,
          onChanged: (value) {
            fade = value;
            changed();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              for (final at in const [0.0, 2.0, 4.0])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: OutlinedButton(
                    onPressed: () {
                      // A jump is an event and the scene is a description, so
                      // the two are reconciled by a token: the renderer acts
                      // when this moves, not when the target does.
                      _seekTo = at;
                      _seekToken++;
                      changed();
                    },
                    child: Text('${at.toStringAsFixed(0)}s'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// What to say when there is nothing to play.
  ///
  /// Four unlit rectangles are what this example looks like with no film, and
  /// they look exactly like a broken renderer. Saying so is the difference
  /// between an example that appears not to work and one that is waiting.
  @override
  Widget? overlay(BuildContext context, VoidCallback changed) {
    final say = trouble ?? (path == null ? 'No film yet.' : null);
    if (say == null) return null;

    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xCC11141A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                say,
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
              const SizedBox(height: 4),
              const Text(
                'Choose one in the panel, and it plays on all four screens.',
                style: TextStyle(fontSize: 11.5, color: Color(0xFFA6B0BF)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  String get code => '''
// The film is on the scene, not on the material. One decoder, however many
// screens are showing it.
OrbisScene(
  videos: [
    OrbisVideo(key: 1, path: '/path/to/a.mp4', playing: true, loop: true),
  ],
  materials: [
    // A screen: unlit, because it makes its own light, and the base colour
    // tints the frame rather than replacing it.
    OrbisMaterial(
      key: 10,
      shading: OrbisShading.video,
      video: 1,
      baseColour: Vector4(1, 1, 1, 1),
    ),
  ],
  objects: [OrbisObject(key: 10, material: 10, transform: ..., colour: ...)],
  camera: camera,
);

// Seeking is an event and the scene is a description, so a token reconciles
// them: the renderer jumps when the token moves, not when the target does.
OrbisVideo(key: 1, path: ..., seekTo: 12.0, seekToken: ++token);
''';
}
