// FILE: lib/services/breadcrumb_navigator_observer.dart
//
// ============================================================================
// WHAT THIS FILE DOES
// ============================================================================
// `BreadcrumbNavigatorObserver` is a `NavigatorObserver` subclass that
// converts every push / pop / replace into a CrashReporter breadcrumb
// + a `current_route` custom-key update. Plug it into
// `MaterialApp.navigatorObservers:` and every navigation event flows
// through Crashlytics's local breadcrumb log.
//
// What gets logged:
//
//   * `didPush(route, previous)` → `'nav: pushed <name> from <prev>'`
//     and sets `current_route = <name>`.
//   * `didPop(route, previous)` → `'nav: popped <name> -> <prev>'`
//     and sets `current_route = <prev>`.
//   * `didReplace({newRoute, oldRoute})` → `'nav: replaced <old> with <new>'`
//     and sets `current_route = <new>`.
//   * `didRemove(route, previous)` → `'nav: removed <name>'`. The
//     `current_route` key isn't updated because remove doesn't
//     necessarily change which route is on top.
//
// Route names are pulled from `RouteSettings.name` when available.
// `MaterialPageRoute<T>(builder:)` calls without a `settings:` argument
// produce nameless routes — those surface as the runtime type
// (`MaterialPageRoute`). The app's screens don't currently use named
// routes globally, so engineers will see a lot of
// `MaterialPageRoute` entries; the boundary error report still shows
// the screen's class name in the stack trace.
//
// ============================================================================
// WHY IT EXISTS IN THE ARCHITECTURE
// ============================================================================
// "We don't track everything the user does in the app" was an
// explicit privacy commitment — but the same property makes a crash
// report harder to triage. Breadcrumbs are local: they sit in
// Crashlytics's in-process log buffer and are only uploaded when a
// crash actually fires. So we can record the user's path through the
// app aggressively (every push / pop) without sending any of that
// data on a normal session — the breadcrumbs only escape the device
// if the app already broke. That's the right privacy trade-off.
//
// ============================================================================
// WHY THIS IS HARDER THAN IT LOOKS
// ============================================================================
//   * Anonymous routes carry no name. Using `runtimeType` is the
//     fallback but `MaterialPageRoute<dynamic>` is uninformative.
//     Engineers should add `settings: RouteSettings(name: 'foo')`
//     on critical routes when the breadcrumb stream needs more
//     specificity. v1 is "log whatever's there" and lives with
//     the gaps.
//   * `RouteSettings.name` is private to the route at construction
//     time. Modal routes (showDialog, showModalBottomSheet) build
//     their own routes via `_DialogRoute` etc., which have no
//     custom name — they appear as "<DialogRoute>" or similar in
//     breadcrumbs. That's still useful: it tells the engineer the
//     user had a dialog open at the time of the crash.
//
// ============================================================================
// WHO CONSUMES THIS FILE
// ============================================================================
//   - lib/app.dart — registers the observer in
//     `MaterialApp.navigatorObservers`.
//
// ============================================================================
// SIDE EFFECTS
// ============================================================================
//   * Calls `CrashReporter.instance.log` and `setKey` on every
//     navigator event. Both are no-ops when Crashlytics is disabled.

import 'package:flutter/material.dart';

import 'crash_reporter.dart';

class BreadcrumbNavigatorObserver extends NavigatorObserver {
  /// Stable identifier for a route the breadcrumb log can render.
  /// Prefers `RouteSettings.name` when set; falls back to the
  /// runtime type for anonymous routes (most of LoadOut's screens
  /// today).
  String _nameOf(Route<dynamic>? route) {
    if (route == null) return '<none>';
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    return route.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    final name = _nameOf(route);
    CrashReporter.instance
        .log('nav: pushed $name from ${_nameOf(previousRoute)}');
    // ignore: discarded_futures
    CrashReporter.instance.setKey('current_route', name);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    final back = _nameOf(previousRoute);
    CrashReporter.instance.log('nav: popped ${_nameOf(route)} -> $back');
    // ignore: discarded_futures
    CrashReporter.instance.setKey('current_route', back);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    final newName = _nameOf(newRoute);
    CrashReporter.instance.log(
      'nav: replaced ${_nameOf(oldRoute)} with $newName',
    );
    // ignore: discarded_futures
    CrashReporter.instance.setKey('current_route', newName);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    CrashReporter.instance.log('nav: removed ${_nameOf(route)}');
  }
}
