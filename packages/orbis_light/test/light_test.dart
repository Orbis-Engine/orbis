import 'dart:math' as math;

import 'package:orbis_light/orbis_light.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  _tintTests();

  group('photometry', () {
    test('watts become lumens at the eye\'s peak efficacy', () {
      // The constant every conversion here rests on: 683 lumens per watt at
      // 555 nm, which is what Blender's own glTF export assumes.
      expect(Photometry.wattsToLumens(1), closeTo(683, 1e-9));
      expect(Photometry.wattsToLumens(1000), closeTo(683000, 1e-6));
    });

    test('a sun\'s irradiance becomes illuminance', () {
      // Blender's default sun is 1 W/m2. Real daylight is around 100,000 lux,
      // so the default is a heavily overcast sky rather than a bright day —
      // worth knowing before wondering why a scene looks flat.
      expect(Photometry.irradianceToLux(1), closeTo(683, 1e-9));
    });

    test('luminous power and intensity round trip through the sphere', () {
      const lumens = 12566.0;
      final candela = Photometry.lumensToCandela(lumens);
      expect(Photometry.candelaToLumens(candela), closeTo(lumens, 1e-9));
      expect(candela, closeTo(lumens / (4 * math.pi), 1e-9));
    });

    test('influence follows the inverse square law', () {
      // Four times the light reaches twice as far, which is the whole shape of
      // how light behaves and the reason a cutoff is needed at all.
      final near = Photometry.influenceRadius(1000);
      final far = Photometry.influenceRadius(4000);
      expect(far, closeTo(near * 2, 1e-6));
    });

    test('a tighter cutoff means a wider influence', () {
      final loose = Photometry.influenceRadius(1000, cutoffLux: 1);
      final tight = Photometry.influenceRadius(1000, cutoffLux: 0.01);
      expect(tight, closeTo(loose * 10, 1e-6));
    });

    test('no light reaches nowhere', () {
      expect(Photometry.influenceRadius(0), 0);
    });
  });

  group('defaults an artist will recognise', () {
    test('a sun is the width the real one is', () {
      expect(
        Light(type: LightType.sun).sunAngle,
        0.526,
        reason:
            'the angular diameter of the sun, and why outdoor shadows '
            'soften with distance rather than staying knife-edged',
      );
    });

    test('a spot opens to forty-five degrees with a soft rim', () {
      final spot = Light(type: LightType.spot);
      expect(spot.spotSize, 45);
      expect(spot.spotBlend, 0.15);
    });

    test('power starts where each type starts in the tool', () {
      expect(Light(type: LightType.point).power, 1000);
      expect(Light(type: LightType.spot).power, 1000);
      expect(Light(type: LightType.area).power, 100);
      expect(
        Light(type: LightType.sun).power,
        1,
        reason: 'a sun is stated per square metre, so its number is small',
      );
    });

    test('a point source has size, so its shadows have an edge', () {
      expect(Light().radius, 0.1);
    });
  });

  group('converting for a renderer', () {
    test('a point light arrives in lumens', () {
      final rendered = Light(type: LightType.point, power: 100).toRenderer();
      expect(rendered.kind, RendererLightKind.point);
      expect(rendered.intensity, closeTo(68300, 1e-6));
    });

    test('a sun arrives in lux and never falls off', () {
      final rendered = Light(type: LightType.sun, power: 3).toRenderer();
      expect(rendered.kind, RendererLightKind.directional);
      expect(rendered.intensity, closeTo(2049, 1e-6));
      expect(
        rendered.falloffRadius,
        double.infinity,
        reason:
            'parallel rays from infinitely far away do not weaken with '
            'distance, and giving them a radius would clip the world',
      );
    });

    test('a sun reports half its angular diameter', () {
      // Renderers ask for the radius of the disc, not its width.
      final rendered = Light(type: LightType.sun, sunAngle: 1.0).toRenderer();
      expect(rendered.sunAngularRadius, closeTo(0.5, 1e-9));
    });

    test('a spot cone becomes inner and outer angles in radians', () {
      final rendered = Light(
        type: LightType.spot,
        spotSize: 60,
        spotBlend: 0.25,
      ).toRenderer();

      // Half of sixty degrees, in radians.
      expect(rendered.outerConeAngle, closeTo(30 * math.pi / 180, 1e-9));
      // Blend eats a quarter of the cone from the outside in.
      expect(rendered.innerConeAngle, closeTo(30 * 0.75 * math.pi / 180, 1e-9));
    });

    test('a hard-edged spot has no falloff band', () {
      final rendered = Light(type: LightType.spot, spotBlend: 0).toRenderer();
      expect(rendered.innerConeAngle, closeTo(rendered.outerConeAngle, 1e-12));
    });

    test('a fully blended spot is gradient all the way to the centre', () {
      final rendered = Light(type: LightType.spot, spotBlend: 1).toRenderer();
      expect(rendered.innerConeAngle, closeTo(0, 1e-12));
    });

    test('a custom distance overrides the derived one', () {
      final derived = Light(type: LightType.point, power: 1000).toRenderer();
      final fixed = Light(
        type: LightType.point,
        power: 1000,
        customDistance: 12,
      ).toRenderer();

      expect(fixed.falloffRadius, 12);
      expect(derived.falloffRadius, isNot(12));
    });

    test('an area light says it was approximated', () {
      final rendered = Light(type: LightType.area).toRenderer();
      expect(
        rendered.approximated,
        isTrue,
        reason:
            'no target renderer has a true area light, and silently '
            'substituting a point is how a scene stops matching its '
            'reference without anyone knowing why',
      );
      expect(Light(type: LightType.point).toRenderer().approximated, isFalse);
    });

    test('an approximated area light keeps a believable penumbra', () {
      // A one metre square becomes the sphere with the same area, so its
      // shadow edge is about as soft as the real shape's would have been.
      final rendered = Light(
        type: LightType.area,
        shape: AreaShape.square,
        sizeX: 1,
      ).toRenderer();
      expect(rendered.sourceRadius, closeTo(math.sqrt(1 / math.pi), 1e-9));
    });
  });

  group('area shapes', () {
    test('a square uses one dimension', () {
      final light = Light(type: LightType.area, sizeX: 2, sizeY: 99);
      expect(light.emittingArea, 4);
    });

    test('a rectangle uses both', () {
      final light = Light(
        type: LightType.area,
        shape: AreaShape.rectangle,
        sizeX: 2,
        sizeY: 3,
      );
      expect(light.emittingArea, 6);
    });

    test('a disk is a circle of that diameter', () {
      final light = Light(
        type: LightType.area,
        shape: AreaShape.disk,
        sizeX: 2,
      );
      expect(light.emittingArea, closeTo(math.pi, 1e-9));
    });

    test('an ellipse uses both radii', () {
      final light = Light(
        type: LightType.area,
        shape: AreaShape.ellipse,
        sizeX: 4,
        sizeY: 2,
      );
      expect(light.emittingArea, closeTo(math.pi * 2 * 1, 1e-9));
    });
  });

  group('the light itself', () {
    test('copies do not share their colour', () {
      final original = Light(color: Vector3(1, 0.5, 0.2));
      final copy = original.copy()..color.x = 0;

      expect(copy.color.x, 0);
      expect(
        original.color.x,
        1,
        reason:
            'a duplicated light that shares a vector is a bug that only '
            'shows up once somebody edits one of them',
      );
    });

    test('response multipliers exist because physics does not have them', () {
      // Killing specular on a fill light is how you stop a second highlight
      // appearing in a character's eyes. No real fixture will do that.
      final light = Light(specular: 0);
      expect(light.specular, 0);
      expect(light.diffuse, 1);
    });
  });
}

void _tintTests() {
  group('a tint', () {
    test('reads a colour the way one is written', () {
      const tint = Tint.hex(0xFF8A3D);
      expect(tint.red, 1.0);
      expect(tint.green, closeTo(0x8A / 255, 1e-9));
      expect(tint.blue, closeTo(0x3D / 255, 1e-9));
    });

    test('converts by the curve sRGB is defined by, not a gamma of 2.2', () {
      // The dark end is where the two disagree enough to see. A gamma of 2.2
      // would put mid-grey at 0.218; the real transfer function puts it at
      // 0.216, and the straight segment near black is off by far more.
      expect(const Tint(0.5, 0.5, 0.5).linear.x, closeTo(0.2140, 1e-3));
      expect(
        const Tint(0.02, 0.02, 0.02).linear.x,
        closeTo(0.02 / 12.92, 1e-9),
      );
      expect(Tint.white.linear.x, closeTo(1.0, 1e-9));
      expect(Tint.black.linear.x, 0.0);
    });

    test('mixes as an eye reads it, not as light adds up', () {
      // Halfway from black to white is mid-grey to look at, which is a fifth
      // of the light. Interpolating linear values would put it at a half,
      // and a dusk ramp done that way spends its whole length nearly black.
      final middle = Tint.lerp(Tint.black, Tint.white, 0.5);
      expect(middle.red, 0.5);
      expect(middle.linear.x, lessThan(0.25));
    });
  });
}
