// SPDX-License-Identifier: GPL-3.0-or-later
// Port of SDR++ core/src/utils/event.h (@8c9f5ee, lines 1-42).
//
// C++ binds `EventHandler<T>*` (function pointer + ctx) and unbinds by pointer identity.
// Dart keeps the same shape: an [EventHandler] object wraps a closure, and
// [Event.unbindHandler] removes by identity, so the same closure may be bound through
// two distinct handler objects and unbound independently (as in C++).

/// `EventHandler<T>`: the C++ `handler(value, ctx)` + `ctx` pair collapses into a closure.
class EventHandler<T> {
  EventHandler(this.handler);

  void Function(T value) handler;
}

/// `Event<T>`.
class Event<T> {
  final List<EventHandler<T>> _handlers = <EventHandler<T>>[];

  /// event.h:21 — calls every bound handler in bind order.
  void emit(T value) {
    // Iterate over a snapshot: a handler may (un)bind handlers while being called.
    if (_handlers.isEmpty) return;
    for (final handler in List<EventHandler<T>>.of(_handlers, growable: false)) {
      handler.handler(value);
    }
  }

  /// event.h:27.
  void bindHandler(EventHandler<T> handler) {
    _handlers.add(handler);
  }

  /// event.h:31 — removes by identity; logs (returns false) if not bound.
  bool unbindHandler(EventHandler<T> handler) {
    final before = _handlers.length;
    _handlers.removeWhere((h) => identical(h, handler));
    return _handlers.length != before;
  }

  /// Convenience: binds [fn] and returns the handler object needed to unbind it.
  EventHandler<T> bind(void Function(T value) fn) {
    final h = EventHandler<T>(fn);
    bindHandler(h);
    return h;
  }

  int get handlerCount => _handlers.length;
}
