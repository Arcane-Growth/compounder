import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/store.dart';
import 'widgets.dart';

/// Animated guided-breathing session: an expanding and contracting bubble
/// sets a box-breathing rhythm (in 4 · hold 4 · out 4 · hold 4) while gentle
/// cues fade in and out. Completed sessions are logged to the mind domain.
class BreathingSession extends StatefulWidget {
  final int minutes;
  const BreathingSession({super.key, required this.minutes});

  @override
  State<BreathingSession> createState() => _BreathingSessionState();
}

class _BreathingSessionState extends State<BreathingSession>
    with TickerProviderStateMixin {
  static const _phaseSeconds = 4;
  static const _cycleSeconds = _phaseSeconds * 4;
  static const _cueIntervalSeconds = 24;

  static const _cues = [
    'Notice your thoughts… let them pass.',
    'Feel the connection of your feet with the ground.',
    'Soften your jaw, your shoulders, your hands.',
    'There is nowhere else you need to be.',
    'With every exhale, release a little more.',
    'Rest your attention on the rhythm of the bubble.',
    'Nothing to fix. Nothing to solve. Just this breath.',
  ];

  late final AnimationController _breath =
      AnimationController(vsync: this, duration: const Duration(seconds: _cycleSeconds));
  int _elapsed = 0;
  Timer? _ticker;
  int _cueIndex = 0;
  bool _finishing = false;

  int get _totalSeconds => widget.minutes * 60;

  @override
  void initState() {
    super.initState();
    _breath.repeat();
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _elapsed++;
        if (_elapsed % _cueIntervalSeconds == 0) {
          _cueIndex = (_cueIndex + 1) % _cues.length;
        }
        if (_elapsed >= _totalSeconds) {
          timer.cancel();
          _complete();
        }
      });
    });
  }

  Future<void> _complete() async {
    setState(() => _finishing = true);
    await context.read<AppStore>().logMeditation(widget.minutes);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _breath.dispose();
    super.dispose();
  }

  Future<void> _confirmCancel() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End session?'),
        content: Text(
            'You have ${formatDuration(_elapsed * 1000, null)} in. Ending early does not log the session.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep breathing')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('End')),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop(false);
  }

  /// (phase label, bubble scale 0..1) for the current moment in the cycle.
  ({String label, double scale}) _phase(double cycleSeconds) {
    if (cycleSeconds < _phaseSeconds) {
      final t = Curves.easeInOut.transform(cycleSeconds / _phaseSeconds);
      return (label: 'Breathe in', scale: 0.55 + 0.45 * t);
    } else if (cycleSeconds < _phaseSeconds * 2) {
      return (label: 'Hold', scale: 1.0);
    } else if (cycleSeconds < _phaseSeconds * 3) {
      final t = Curves.easeInOut.transform((cycleSeconds - _phaseSeconds * 2) / _phaseSeconds);
      return (label: 'Breathe out', scale: 1.0 - 0.45 * t);
    }
    return (label: 'Hold', scale: 0.55);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: scheme.brightness == Brightness.dark
          ? const Color(0xFF0B1210)
          : const Color(0xFFF2F7F0),
      body: Stack(
        children: [
          Center(
            child: AnimatedBuilder(
              animation: _breath,
              builder: (context, _) {
                final cycle = _breath.value * _cycleSeconds;
                final phase = _phase(cycle);
                final remaining = _phaseSeconds - (cycle % _phaseSeconds);
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    height: 320,
                    width: 320,
                    child: Stack(alignment: Alignment.center, children: [
                      Transform.scale(
                        scale: phase.scale,
                        child: Container(
                          height: 300,
                          width: 300,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                scheme.primary.withValues(alpha: 0.75),
                                scheme.primary.withValues(alpha: 0.18),
                                scheme.primary.withValues(alpha: 0.0),
                              ],
                              stops: const [0.2, 0.75, 1.0],
                            ),
                          ),
                        ),
                      ),
                      Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(phase.label,
                            style: t.headlineSmall?.copyWith(color: scheme.onSurface)),
                        const SizedBox(height: 6),
                        Text('$remaining',
                            style: t.headlineMedium?.copyWith(color: scheme.primary)),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    height: 48,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 1600),
                      switchInCurve: Curves.easeIn,
                      switchOutCurve: Curves.easeOut,
                      child: Text(
                        _cues[_cueIndex],
                        key: ValueKey(_cueIndex),
                        textAlign: TextAlign.center,
                        style: t.bodyLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ),
                ]);
              },
            ),
          ),
          Positioned(
            top: 16,
            left: 16,
            child: IconButton(
              icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
              onPressed: _finishing ? null : _confirmCancel,
            ),
          ),
          Positioned(
            bottom: 28,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                _finishing
                    ? 'Session complete — logged.'
                    : '${formatDuration(_elapsed * 1000, null)} / ${widget.minutes}:00',
                style: t.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
