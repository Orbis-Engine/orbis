# orbis_input

Gamepads as state a frame can ask about, and as the handful of things that
happened between two frames.

Part of [Orbis](https://github.com/Orbis-Engine/orbis), a Dart-first 3D game
engine. The documentation is at [orbis-site.vercel.app](https://orbis-site.vercel.app).

## Using it

```yaml
dependencies:
  orbis_input:
    git:
      url: https://github.com/Orbis-Engine/orbis.git
      path: packages/orbis_input
```

Needs Dart alone. Runs anywhere Dart runs, including a headless CI runner —
on a platform with no backend it reports no pads rather than failing.

```dart
final pads = Pads.open();

// Once a frame.
final frame = pads.poll();
final pad = frame.first;

move(pad.stick(PadStick.left) * speed * delta);
if (pad.wasPressed(PadButton.south)) jump();
if (pad.trigger(PadSide.right) > 0.5) fire();

// The things a snapshot cannot hold: a tap and release inside one frame,
// and a pad arriving or leaving.
for (final event in frame.events) {
  if (event case PadDisconnected()) pause();
}
```

## What it does

- **State and events, from one poll.** `PadState` answers "is it down now" and
  "did it go down since the last frame"; `PadFrame.events` carries what a
  snapshot cannot express.
- **Dead zones and curves**, radial rather than per-axis, with the rescaling
  that keeps the output continuous where the zone ends.
- **Layouts** from the kernel's own gamepad codes, with a small table for the
  pads whose labels or axes differ. No external controller database.
- **Hot-plug.** A pad that vanishes reads as neutral rather than as whatever
  it was holding, and takes its slot back when it returns.

Linux, through evdev, so far. The platform's own gamepad interface behind the
same front door is what the other platforms will be.

Not here: rumble, motion sensors, touchpads, and pointer lock.

## Status

Pre-alpha. Nothing here is API-stable, and the version is bumped for every
feature — see [VERSIONING.md](../../VERSIONING.md).

## Licence

MIT, © 2026 Chris Beckett. See [LICENSE](LICENSE), and the repository root
for the third-party notices that apply to builds linking the renderer.
