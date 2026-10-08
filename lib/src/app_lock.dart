/// The app lock, drawn above the Navigator.
///
/// The lock used to be the content of the home route, and every other route
/// was popped when it engaged. That had two flaws. A dialog, sheet or page an
/// action opened afterwards lay above the lock screen. And the popping threw
/// away what was open: unsaved text in the config editor, the Pi-hole password
/// that is shown only once, a running update of several Pis.
///
/// Now the lock is no route. [AppLockLayer] sits in MaterialApp.builder and
/// covers the whole Navigator while the app is locked: every route — open
/// before or pushed since — stays where it is, out of sight and out of reach,
/// and is back with the unlock.
///
/// When to lock and how to authenticate stays with the page. It reports
/// through the [AppLockController] it finds with [AppLockLayer.maybeOf].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;

/// Shared by the page that owns the lock logic and the widgets here that draw
/// the lock: whether the app is locked, and what the button on the lock screen
/// does.
class AppLockController extends ChangeNotifier {
  Object? _owner;
  VoidCallback? _onUnlock;
  bool _locked = false;

  // What the Navigator last reported: whether system back has something to
  // pop. Held back from the platform while locked, see [_AppLockScopeState].
  bool _canHandlePop = false;

  // The two places the keyboard focus can be in: the Navigator and the lock
  // screen. [AppLockLayer] puts them into the tree, [_AppLockScopeState] opens
  // the one and closes the other with the lock.
  final _navigatorFocus = FocusScopeNode(debugLabel: 'App lock: Navigator');
  final _lockScreenFocus = FocusScopeNode(
      debugLabel: 'App lock: lock screen', canRequestFocus: false);

  @override
  void dispose() {
    _navigatorFocus.dispose();
    _lockScreenFocus.dispose();
    super.dispose();
  }

  /// True while the lock covers the app.
  bool get locked => _locked;
  set locked(bool value) {
    if (value == _locked) return;
    _locked = value;
    notifyListeners();
  }

  /// The page takes the lock over: [onUnlock] is what the button on the lock
  /// screen does (ask for the fingerprint or the PIN).
  void attach(Object owner, {required VoidCallback onUnlock}) {
    _owner = owner;
    _onUnlock = onUnlock;
  }

  /// The page is gone. A lock that is up stays up — nothing in here unlocks
  /// without an authentication — and the next page to [attach] gets the
  /// button.
  void detach(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _onUnlock = null;
  }

  /// The button on the lock screen.
  void requestUnlock() => _onUnlock?.call();

  bool _onNavigationNotification(NavigationNotification notification) {
    _canHandlePop = notification.canHandlePop;
    return _locked; // true = the report stops here
  }
}

/// Goes above MaterialApp. Holds the [AppLockController] for everything
/// beneath and answers system back while the app is locked.
class AppLockScope extends StatefulWidget {
  const AppLockScope({super.key, required this.child});

  final Widget child;

  @override
  State<AppLockScope> createState() => _AppLockScopeState();
}

class _AppLockScopeState extends State<AppLockScope>
    with WidgetsBindingObserver {
  final _controller = AppLockController();

  @override
  void initState() {
    super.initState();
    // The binding asks its observers in the order they registered, and this
    // State exists before the WidgetsApp inside MaterialApp: system back
    // comes here first, before the Navigator hears of it.
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onLockChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  void _onLockChanged() {
    final navigator = _controller._navigatorFocus;
    final lockScreen = _controller._lockScreenFocus;
    if (_controller.locked) {
      // Close the keyboard with the lock, not with the next frame: the app
      // locks in the background, where no frame is drawn. A field or control
      // that had the focus gives it to its route and is not remembered — the
      // keyboard does not come up by itself after the unlock. A route that
      // has the focus itself is left alone: unfocusing a scope makes the
      // scope around it forget its children, and the unlock could not return
      // to that route.
      final focus = FocusManager.instance.primaryFocus;
      if (focus is! FocusScopeNode) focus?.unfocus();
      // Out of the Navigator with the focus, in this call as well. A widget
      // could only do that with its next build, and until then Tab and Space
      // from a hardware keyboard still reached the route on top — with the
      // settings open they switched the app lock off.
      navigator.canRequestFocus = false;
      lockScreen
        ..canRequestFocus = true
        ..requestFocus();
    } else {
      // Back to the route on top. Left where the lock screen had it, the
      // focus would be on nothing: no Tab and no Escape until a tap.
      lockScreen.canRequestFocus = false;
      navigator
        ..canRequestFocus = true
        ..requestFocus();
    }
    // System back. On the lock screen it has always been the platform's: with
    // the home route alone the framework tells it "nothing to pop here", and
    // back leaves the app. Routes that stay beneath the lock must not change
    // that. Where the system reports a back gesture while it happens
    // (predictive back), the gesture would go straight to a page route down
    // there: each one follows it as a binding observer of its own, and no
    // observer can hold another one back. So while locked the platform is
    // told that back is its own, whatever the Navigator reports, and with the
    // unlock it gets the Navigator's last word.
    SystemNavigator.setFrameworkHandlesBack(
            !_controller.locked && _controller._canHandlePop)
        .catchError((Object _) {});
  }

  /// Where Android still calls the activity's onBackPressed, back reaches the
  /// framework whatever it was told above (FlutterFragmentActivity forwards it
  /// unconditionally). The lock is no route, so the Navigator would pop what
  /// lies hidden beneath it — instead back does here what it does on a lock
  /// screen: it leaves the app.
  @override
  Future<bool> didPopRoute() async {
    if (!_controller.locked) return false; // on to the Navigator
    SystemNavigator.pop().catchError((Object _) {});
    return true;
  }

  @override
  Widget build(BuildContext context) =>
      _AppLockInherited(controller: _controller, child: widget.child);
}

// Hands the controller from the scope down to the layer.
class _AppLockInherited extends InheritedWidget {
  const _AppLockInherited({required this.controller, required super.child});

  final AppLockController controller;

  @override
  bool updateShouldNotify(_AppLockInherited oldWidget) =>
      !identical(controller, oldWidget.controller);
}

// Marks what an [AppLockLayer] covers, see [AppLockLayer.maybeOf].
class _AppLockCovered extends InheritedWidget {
  const _AppLockCovered({required this.controller, required super.child});

  final AppLockController controller;

  @override
  bool updateShouldNotify(_AppLockCovered oldWidget) =>
      !identical(controller, oldWidget.controller);
}

/// Goes into MaterialApp.builder, around the Navigator ([child]).
///
/// While the app is locked the lock screen lies over the Navigator, and the
/// Navigator is offstage: not painted, not hit-tested, not in the semantics
/// tree, and nothing in it can take the focus. It is never taken out of the
/// tree — its place there does not depend on the lock — so every route keeps
/// its state, and a route pushed while locked simply lands beneath.
///
/// Deliberately small, without state of its own and without a platform call:
/// a fault in here would leave an app that is locked for good.
class AppLockLayer extends StatelessWidget {
  const AppLockLayer({
    super.key,
    required this.lockScreen,
    required this.child,
  });

  /// Builds the lock screen; `onUnlock` is what its button does.
  final Widget Function(VoidCallback onUnlock) lockScreen;

  /// The Navigator, as MaterialApp.builder hands it over.
  final Widget child;

  /// The controller of the lock layer that covers [context] — or null when
  /// none does, as for a page that a widget test pumps on its own. Whoever
  /// gets null has to keep its content away by itself while locked.
  ///
  /// Found only beneath a layer that is really in the tree, never through the
  /// [AppLockScope] alone. Usable in initState: the controller lives as long
  /// as the scope, nothing is rebuilt for it.
  static AppLockController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_AppLockCovered>()?.controller;

  @override
  Widget build(BuildContext context) {
    final controller = context
        .getInheritedWidgetOfExactType<_AppLockInherited>()
        ?.controller;
    if (controller == null) return child; // no scope above: nothing can lock
    return ListenableBuilder(
      listenable: controller,
      child: _AppLockCovered(
        controller: controller,
        // Between the Navigator and the WidgetsApp that passes its reports on
        // to the platform — the one place where they can be held back, see
        // [_AppLockScopeState._onLockChanged].
        child: NotificationListener<NavigationNotification>(
          onNotification: controller._onNavigationNotification,
          child: child,
        ),
      ),
      builder: (context, navigator) {
        final locked = controller.locked;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Each side in a focus scope the lock opens and closes from
            // outside — in the call that locks, not with this build (see
            // [_AppLockScopeState._onLockChanged]). Both stay in the tree, so
            // the focus can go to either one at any time.
            FocusScope.withExternalFocusNode(
              focusScopeNode: controller._navigatorFocus,
              includeSemantics: false,
              child: Offstage(offstage: locked, child: navigator),
            ),
            FocusScope.withExternalFocusNode(
              focusScopeNode: controller._lockScreenFocus,
              includeSemantics: false,
              // A ScaffoldMessenger of its own: on the app's, the lock screen
              // would show a snackbar raised beneath it, action included.
              child: locked
                  ? ScaffoldMessenger(
                      child: lockScreen(controller.requestUnlock))
                  : const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }
}
