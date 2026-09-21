import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// Displays the current audio segment, using the player's actual timestamps.
class VoicePlaybackProgress extends StatefulWidget {
  const VoicePlaybackProgress({super.key, required this.player});
  final AudioPlayer player;
  @override
  State<VoicePlaybackProgress> createState() => _VoiceProgressState();
}

class _VoiceProgressState extends State<VoicePlaybackProgress> {
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _drag;
  int _sourceRevision = 0;
  int _dragRevision = 0;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  @override
  void initState() {
    super.initState();
    _subscriptions.add(
      widget.player.onPositionChanged.listen((v) {
        if (mounted) setState(() => _position = v);
      }),
    );
    _subscriptions.add(
      widget.player.onDurationChanged.listen((v) {
        if (mounted) setState(() => _duration = v);
      }),
    );
    _subscriptions.add(
      widget.player.onPlayerStateChanged.listen((v) {
        if (mounted &&
            (v == PlayerState.stopped || v == PlayerState.completed)) {
          _sourceRevision++;
          setState(() {
            _position = Duration.zero;
            _duration = Duration.zero;
            _drag = null;
          });
        }
      }),
    );
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  String _time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
    child: Row(
      children: [
        const Icon(Icons.graphic_eq, size: 12),
        const SizedBox(width: 4),
        Expanded(
          child: SizedBox(
            height: 28,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value:
                    _drag ??
                    (_duration.inMilliseconds > 0
                        ? (_position.inMilliseconds / _duration.inMilliseconds)
                              .clamp(0.0, 1.0)
                        : 0),
                onChangeStart: _duration > Duration.zero
                    ? (_) => _dragRevision = _sourceRevision
                    : null,
                onChanged: _duration > Duration.zero
                    ? (v) => setState(() => _drag = v)
                    : null,
                onChangeEnd: _duration > Duration.zero
                    ? (v) async {
                        final target = Duration(
                          milliseconds: (_duration.inMilliseconds * v).round(),
                        );
                        try {
                          if (_dragRevision == _sourceRevision) {
                            await widget.player.seek(target);
                          }
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text('$error')));
                          }
                        } finally {
                          if (mounted) setState(() => _drag = null);
                        }
                      }
                    : null,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          '${_time(_position)} / ${_time(_duration)}',
          style: const TextStyle(fontSize: 10),
        ),
      ],
    ),
  );
}
