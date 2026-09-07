import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:orbis_filament/orbis_filament.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

/// One thing the engine does, shown on its own.
///
/// Each example owns its own state and hands back a whole scene when asked
/// for one. Nothing is shared between them but the surface they are drawn on,
/// which is the point: what any of them needs to work is what is written in
/// its own file, and that is what the code panel shows.
abstract class Example {
  const Example();

  /// What it is called in the list.
  String get name;

  /// One line on what it shows.
  String get blurb;

  /// Where the camera starts, so an example opens framed on its subject.
  ViewPoint get viewpoint => const ViewPoint();

  /// The scene as it stands, given where the camera is and how long this
  /// example has been on screen.
  ///
  /// Called every frame. Building a whole scene each time is the engine's
  /// intended shape — the description is complete, the objects in it are
  /// keyed, and the renderer works out what actually changed.
  OrbisScene scene(OrbisCamera camera, double seconds);

  /// The controls that change it. Call [changed] when one moves.
  Widget settings(BuildContext context, VoidCallback changed);

  /// The lines that matter, as somebody would write them.
  String get code;

  /// Anything drawn over the scene rather than in it.
  ///
  /// Null for the examples that are only about what the renderer does. Call
  /// [changed] when something in it has moved.
  Widget? overlay(BuildContext context, VoidCallback changed) => null;
}

/// Where an example starts looking from.
class ViewPoint {
  const ViewPoint({
    this.yaw = 0.7,
    this.pitch = 0.32,
    this.distance = 11,
    this.height = 0.5,
    this.fieldOfView = 50,
  });

  final double yaw;
  final double pitch;
  final double distance;
  final double height;
  final double fieldOfView;
}

/// The camera the gallery orbits with.
///
/// Deliberately the simplest thing that works: an editor's camera has to
/// survive being driven into corners, and this one only has to let somebody
/// look at what an example is showing them.
class GalleryCamera {
  GalleryCamera.from(ViewPoint start)
    : yaw = start.yaw,
      pitch = start.pitch,
      distance = start.distance,
      height = start.height,
      fieldOfView = start.fieldOfView;

  double yaw;
  double pitch;
  double distance;
  double height;
  double fieldOfView;

  void orbit(Offset delta) {
    yaw -= delta.dx * 0.008;
    // Short of straight up and straight down, where the view matrix collapses
    // and the image flips over.
    pitch = (pitch + delta.dy * 0.008).clamp(-1.5, 1.5);
  }

  void zoom(double amount) {
    distance = (distance * (1 + amount * 0.0016)).clamp(1.5, 400.0);
  }

  OrbisCamera toRenderCamera() {
    final flat = distance * math.cos(pitch);
    return OrbisCamera(
      position: Vector3(
        flat * math.sin(yaw),
        height + distance * math.sin(pitch),
        flat * math.cos(yaw),
      ),
      target: Vector3(0, height, 0),
      fieldOfView: fieldOfView,
    );
  }
}

/// A named slider, at the size the panel wants it.
class Setting extends StatelessWidget {
  const Setting({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onSettled,
    this.unit = '',
    this.decimals = 2,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  /// Called once, when the handle is let go.
  ///
  /// For the settings whose answer is expensive. A slider reports every pixel
  /// of a drag, and something that lays a hundred thousand objects out again
  /// each time it hears one is a slider that cannot be dragged.
  final ValueChanged<double>? onSettled;
  final String unit;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
                onChangeEnd: onSettled,
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              '${value.toStringAsFixed(decimals)}$unit',
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontFamily: 'Menlo', fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

/// A row of things to pick between.
class Choice extends StatelessWidget {
  const Choice({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final String label;
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final option in options)
                  GestureDetector(
                    onTap: () => onSelect(option),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: option == selected
                            ? const Color(0xFFC25E22)
                            : const Color(0xFF232833),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        option,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: option == selected
                              ? Colors.white
                              : const Color(0xFF98A2B3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A switch, for the settings that are one thing or the other.
class Toggle extends StatelessWidget {
  const Toggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Choice(
    label: label,
    options: const ['Off', 'On'],
    selected: value ? 'On' : 'Off',
    onSelect: (option) => onChanged(option == 'On'),
  );
}
