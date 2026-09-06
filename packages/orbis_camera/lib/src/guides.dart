/// A rectangle over the frame, in fractions of it.
///
/// Measured from the top-left corner because that is where every drawing
/// surface starts, and in fractions because composition is about proportions:
/// a rule written in pixels stops meaning what it meant the moment the window
/// is resized, which is the whole reason the framing itself is in normalised
/// coordinates.
class ScreenRect {
  const ScreenRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  bool contains(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;

  @override
  String toString() =>
      'ScreenRect(${left.toStringAsFixed(3)}, ${top.toStringAsFixed(3)}, '
      '${width.toStringAsFixed(3)} x ${height.toStringAsFixed(3)})';
}

/// What a camera's framing looks like, for something to draw.
///
/// The rules a composer works by are invisible, and that is the problem with
/// them: somebody tuning a shot is moving numbers and guessing at what they
/// mean. Drawn over the frame they stop being numbers — the subject sits
/// inside the dead zone and the camera holds still, it crosses into the soft
/// zone and the camera eases after it, and where those edges are is something
/// to look at rather than something to work out.
///
/// Handed out as plain fractions rather than drawn here, because this package
/// has no idea what it is being drawn with.
class CameraGuides {
  const CameraGuides({
    required this.screenX,
    required this.screenY,
    required this.dead,
    required this.soft,
  });

  /// Where the subject is meant to sit, in fractions of the frame.
  final double screenX;
  final double screenY;

  /// Where the camera does not move.
  ///
  /// A subject drifting inside this rectangle is left alone. Without it a
  /// camera corrects for every twitch of whatever it is following, which
  /// reads as a nervous operator rather than a steady one.
  final ScreenRect dead;

  /// Where the camera eases after the subject.
  ///
  /// Outside the dead zone and inside this one, the camera is catching up,
  /// damped. Past its edge it is dragged rigidly, because at that point the
  /// subject is about to leave the frame and holding the shot matters less
  /// than keeping them in it.
  final ScreenRect soft;
}
