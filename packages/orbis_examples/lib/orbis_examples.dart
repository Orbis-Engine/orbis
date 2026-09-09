/// One technique at a time: a scene that shows it, the controls that change
/// it, and the lines that do it.
///
/// A package rather than part of the gallery app, because two things want to
/// show them. The gallery is a window with a list down one side; the editor
/// shows the same examples beside the projects somebody is actually working
/// on, which is where a question about how something is done tends to be
/// asked.
///
/// Each example owns its own state and hands back a whole scene when asked
/// for one. Nothing is shared between them but the surface they are drawn on:
/// what any of them needs to work is what is written in its own file, and
/// that is what the code panel shows.
///
/// **These are the examples that need nothing but the engine.** The ones that
/// run TypeScript live in the gallery app beside the scripting runtime they
/// need — putting them here would mean every host of this package building
/// QuickJS to show eleven examples that never touch it.
library;

export 'src/example.dart'
    show
        Choice,
        Downloadable,
        Example,
        GalleryCamera,
        Setting,
        Toggle,
        ViewPoint;
export 'src/examples/benchmark.dart' show BenchmarkExample;
export 'src/examples/blend.dart' show BlendExample;
export 'src/examples/bounce.dart' show BounceExample;
export 'src/examples/field.dart' show FieldExample;
export 'src/examples/bistro.dart'
    show BistroExteriorExample, BistroFixture, BistroInteriorExample;
export 'src/examples/cameras.dart' show CamerasExample;
export 'src/examples/crowd.dart' show CrowdExample;
export 'src/examples/day_and_night.dart' show DayAndNightExample;
export 'src/examples/lights.dart' show LightsExample;
export 'src/examples/many.dart' show ManyExample;
export 'src/examples/materials.dart' show MaterialsExample;
export 'src/examples/meshes.dart' show MeshesExample;
export 'src/examples/pipeline.dart' show PipelineExample;
export 'src/examples/runner.dart' show RunnerExample;
export 'src/examples/post.dart' show PostExample;
export 'src/examples/video.dart' show VideoExample;
export 'src/examples/voxels.dart' show VoxelExample;
export 'src/examples/weather.dart' show WeatherExample;
export 'src/examples/surface.dart' show SurfaceExample, linearOf;

import 'src/example.dart';
import 'src/examples/benchmark.dart';
import 'src/examples/blend.dart';
import 'src/examples/bounce.dart';
import 'src/examples/field.dart';
import 'src/examples/bistro.dart';
import 'src/examples/cameras.dart';
import 'src/examples/crowd.dart';
import 'src/examples/day_and_night.dart';
import 'src/examples/lights.dart';
import 'src/examples/many.dart';
import 'src/examples/materials.dart';
import 'src/examples/meshes.dart';
import 'src/examples/pipeline.dart';
import 'src/examples/runner.dart';
import 'src/examples/post.dart';
import 'src/examples/surface.dart';
import 'src/examples/video.dart';
import 'src/examples/voxels.dart';
import 'src/examples/weather.dart';

/// Every example that needs nothing but the engine, in the order to show them.
///
/// A function rather than a constant list, so that each caller gets its own
/// instances: an example owns its settings, and two windows showing the same
/// one should not be moving each other's sliders.
///
/// The order is the order somebody should meet them in — a surface, then what
/// lights it, then what the air does to it — rather than alphabetical, which
/// would open on a benchmark.
List<Example> engineExamples() => [
  SurfaceExample(),
  LightsExample(),
  BounceExample(),
  FieldExample(),
  DayAndNightExample(),
  WeatherExample(),
  ManyExample(),
  CrowdExample(),
  CamerasExample(),
  MeshesExample(),
  MaterialsExample(),
  BlendExample(),
  PipelineExample(),
  PostExample(),
  VideoExample(),
  VoxelExample(),
  RunnerExample(),
  BistroExteriorExample(),
  BistroInteriorExample(),
  BenchmarkExample(),
];
