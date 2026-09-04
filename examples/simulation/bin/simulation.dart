import 'package:orbis_simulation_example/simulation.dart';

/// Runs the slice and prints where things ended up, so the engine can be
/// exercised without a window.
void main() {
  final sim = Simulation();
  final body = sim.spawnBody(x: 0, y: 0, speed: 2);
  final carried = sim.attach(body, offsetY: 1);
  // Nothing has a world transform until the first propagation, so tick zero
  // would otherwise report everything at the origin.
  sim.step(0);

  print('tick  body                    attachment');
  for (var tick = 0; tick <= 5; tick++) {
    if (tick > 0) sim.step(0.2);
    final b = worldPositionOf(sim.world, sim.transforms, body);
    final c = worldPositionOf(sim.world, sim.transforms, carried);
    print('${tick.toString().padRight(6)}'
        '${_fmt(b).padRight(24)}${_fmt(c)}');
  }
  sim.dispose();
}

String _fmt(List<double> v) =>
    '(${v.map((n) => n.toStringAsFixed(2)).join(', ')})';
