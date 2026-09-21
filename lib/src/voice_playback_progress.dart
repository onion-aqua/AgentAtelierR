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
          setState(() {
            _position = Duration.zero;
            _duration = Duration.zero;
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
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Row(
      children: [
        const Icon(Icons.graphic_eq, size: 14),
        const SizedBox(width: 8),
        Expanded(
          child: LinearProgressIndicator(
            value: _duration.inMilliseconds > 0
                ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(
                    0.0,
                    1.0,
                  )
                : 0,
            minHeight: 3,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${_time(_position)} / ${_time(_duration)}',
          style: const TextStyle(fontSize: 10),
        ),
      ],
    ),
  );
}
