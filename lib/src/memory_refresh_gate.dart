/// A load invalidates old requests without letting their completion release
/// the lock or pending work owned by a newer request.
class MemoryRefreshGate {
  int _generation = 0;
  bool running = false;
  bool refreshAfterLoad = false;
  int? begin() {
    if (running) return null;
    running = true;
    return ++_generation;
  }

  bool owns(int token) => token == _generation;
  bool finish(int token) {
    if (!owns(token)) return false;
    running = false;
    return true;
  }

  void invalidate({bool afterLoad = false}) {
    _generation++;
    running = false;
    refreshAfterLoad = afterLoad;
  }
}
