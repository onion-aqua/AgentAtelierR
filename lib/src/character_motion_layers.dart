class MotionLayerLease {
  const MotionLayerLease({
    required this.token,
    required this.groupId,
    required this.tracks,
    required this.expiresAt,
  });

  final int token;
  final String groupId;
  final Set<int> tracks;
  final DateTime expiresAt;
}

/// Owns only gesture tracks. Face, speech, and the base pose use other tracks.
class CharacterMotionLayers {
  final _leases = <int, MotionLayerLease>{};
  final _trackOwners = <int, int>{};

  bool get isNotEmpty => _trackOwners.isNotEmpty;
  bool canOverlap(Iterable<int> tracks) =>
      isNotEmpty && tracks.every((track) => !_trackOwners.containsKey(track));

  List<MotionLayerLease> get active => List.unmodifiable(_leases.values);
  DateTime? get latestExpiry {
    DateTime? latest;
    for (final lease in _leases.values) {
      if (latest == null || lease.expiresAt.isAfter(latest)) {
        latest = lease.expiresAt;
      }
    }
    return latest;
  }

  String? get latestGroupId =>
      _leases.isEmpty ? null : _leases.values.last.groupId;

  void claim(
    int token,
    String groupId,
    Iterable<int> tracks,
    DateTime expiresAt,
  ) {
    final owned = tracks.where((track) => track >= 2 && track <= 10).toSet();
    if (owned.isEmpty) return;
    for (final track in owned) {
      final previous = _trackOwners[track];
      if (previous == null) continue;
      final lease = _leases[previous];
      if (lease == null) continue;
      final remainder = lease.tracks.difference({track});
      if (remainder.isEmpty) {
        _leases.remove(previous);
      } else {
        _leases[previous] = MotionLayerLease(
          token: previous,
          groupId: lease.groupId,
          tracks: remainder,
          expiresAt: lease.expiresAt,
        );
      }
    }
    for (final track in owned) {
      _trackOwners[track] = token;
    }
    _leases[token] = MotionLayerLease(
      token: token,
      groupId: groupId,
      tracks: owned,
      expiresAt: expiresAt,
    );
  }

  Set<int> release(int token) {
    final lease = _leases.remove(token);
    if (lease == null) return const {};
    for (final track in lease.tracks) {
      if (_trackOwners[track] == token) _trackOwners.remove(track);
    }
    return lease.tracks;
  }

  void clear() {
    _leases.clear();
    _trackOwners.clear();
  }
}
