import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Swipe-to-delete that ignores scrolls. Plain Dismissible deletes on any
/// quick sideways flick, however short, so a slightly diagonal scroll could
/// delete an item. Here a swipe only counts if the finger really travelled
/// sideways ([isDeliberateSwipe]), and the row waits longer before claiming a
/// drag, so the list's vertical scroll wins ambiguous gestures.
class DeliberateSwipe extends StatefulWidget {
  const DeliberateSwipe({
    super.key,
    required this.dismissKey,
    required this.onDismissed,
    required this.background,
    required this.secondaryBackground,
    required this.child,
  });

  final Key dismissKey;
  final VoidCallback onDismissed;
  final Widget background;
  final Widget secondaryBackground;
  final Widget child;

  @override
  State<DeliberateSwipe> createState() => _DeliberateSwipeState();
}

/// Twice Flutter's default (18): the row needs a clearer sideways start
/// before it takes the gesture from the list's scrolling.
const _swipeSlop = 36.0;

class _DeliberateSwipeState extends State<DeliberateSwipe> {
  Offset? _start;
  Offset _travel = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Listener(
      onPointerDown: (e) {
        _start = e.position;
        _travel = Offset.zero;
      },
      onPointerMove: (e) {
        if (_start != null) _travel = e.position - _start!;
      },
      child: LayoutBuilder(
        builder: (context, constraints) => MediaQuery(
          data: media.copyWith(gestureSettings: const DeviceGestureSettings(touchSlop: _swipeSlop)),
          child: Dismissible(
            key: widget.dismissKey,
            direction: DismissDirection.horizontal,
            dismissThresholds: const {DismissDirection.startToEnd: 0.5, DismissDirection.endToStart: 0.5},
            confirmDismiss: (_) async => isDeliberateSwipe(_travel.dx, _travel.dy, constraints.maxWidth),
            onDismissed: (_) => widget.onDismissed(),
            background: widget.background,
            secondaryBackground: widget.secondaryBackground,
            child: MediaQuery(data: media, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// A finger that moved [dx], [dy] across a row [width] wide meant to delete:
/// at least 35% of the row sideways, and mostly sideways (under ~27° off
/// horizontal), not a flick or a scroll that drifted.
bool isDeliberateSwipe(double dx, double dy, double width) => dx.abs() >= width * 0.35 && dx.abs() >= dy.abs() * 2;
