# Changelog

## 0.1.0

- First cut of `orbis_input`. Pre-alpha: everything is subject to change.

- Gamepads as both polled state and events from one `Pads.poll()` — `PadState`
  for what is held now and what changed since the last frame, `PadFrame.events`
  for the tap that began and ended inside one frame and for pads arriving and
  leaving.

- Dead zones and response curves owned by the engine: radial on a stick,
  scalar on a trigger, rescaled so deflection is continuous where the zone
  ends.

- Layouts built on the kernel's own gamepad button and axis codes, with a
  small table for the pads whose labels or axes differ from them, and a
  predictable fallback for pads in neither. No external controller database.

- A Linux backend over evdev: sysfs to find and classify a pad, `dart:ffi` to
  libc to read it. No compiled code of our own.
