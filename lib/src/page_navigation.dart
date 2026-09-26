/// Navigation history for pages kept in the same root route. Selecting home
/// explicitly starts a fresh history; returning never records a new entry.
class PageNavigation<T> {
  PageNavigation(this.home) : _pages = [home];

  final T home;
  final List<T> _pages;
  T get current => _pages.last;
  bool get canGoBack => _pages.length > 1;
  T? get previous => canGoBack ? _pages[_pages.length - 2] : null;

  void select(T page) {
    if (page == home) {
      _pages
        ..clear()
        ..add(home);
    } else if (page != current) {
      _pages.add(page);
    }
  }

  void goBack() {
    if (canGoBack) _pages.removeLast();
  }
}
