import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:idr_target/idr_target.dart';
import 'package:idr_telemetry/idr_telemetry.dart' show runGuarded;
import 'package:idr_telemetry_flutter/idr_telemetry_flutter.dart';

import 'screens/flow_screens.dart';
import 'screens/home/home_screen.dart';
import 'target/target_controller.dart';

import 'ui/index.dart'; // Theme used

/// `--flavor dev|staging|prod` picks `config/<name>.json`; without it a
/// release build is prod and `flutter run` is dev ([IdrFlavor.defaultName]).
/// Matches pubspec `version:`; shown in every log record.
const _appVersion = '1.0.0+1';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  IdrFlavor.init(args);
  try {
    await TelemetryFlutter.init(service: 'idr_target_app', serviceVersion: _appVersion);
  } on Object {
    // Logging never stops the app.
  }
  // Uncaught errors become crash records (docs/observability/04 §3).
  runGuarded(() => runApp(const TargetApp()));
}

class TargetApp extends StatefulWidget {
  const TargetApp({super.key, this.controller});

  /// Injected by tests; the app builds its own SDK-backed controller otherwise.
  final TargetController? controller;

  @override
  State<TargetApp> createState() => _TargetAppState();
}

/// What closing the window does while this app's agent serves.
enum _OnClose { tray, stop }

class _TargetAppState extends State<TargetApp> {
  late final TargetController _c = widget.controller ?? TargetController();
  final _nav = GlobalKey<NavigatorState>();

  /// Windows runner (flutter_window.cpp): `hideToTray`; the tray menu calls `quit`.
  static const _window = MethodChannel('idr/window');
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _c.boot();
    _life = AppLifecycleListener(onExitRequested: _onExitRequested);
    _window.setMethodCallHandler((call) async {
      if (call.method == 'quit') await _stopAndExit();
    });
  }

  @override
  void dispose() {
    _life.dispose();
    _c.dispose();
    super.dispose();
  }

  /// Closing the window would orphan the agent: ask whether to keep serving
  /// from the tray or stop it.
  Future<AppExitResponse> _onExitRequested() async {
    if (!_c.ownsAgent) return AppExitResponse.exit;
    final ctx = _nav.currentContext;
    final choice = ctx == null
        ? _OnClose.stop
        : await showDialog<_OnClose>(
            context: ctx,
            builder: (ctx) => AlertDialog(
              title: const Text('Close idr Target?'),
              content: const Text(
                'The Target agent is serving this machine. Keep it running in '
                'the system tray, or stop it and exit?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, _OnClose.stop),
                  child: const Text('Stop agent and exit'),
                ),
                if (Platform.isWindows)
                  FilledButton(
                    autofocus: true,
                    onPressed: () => Navigator.pop(ctx, _OnClose.tray),
                    child: const Text('Keep running in tray'),
                  ),
              ],
            ),
          );
    switch (choice) {
      case _OnClose.tray:
        await _window.invokeMethod<void>('hideToTray');
        return AppExitResponse.cancel;
      case _OnClose.stop:
        await _c.target.stop();
        return AppExitResponse.exit;
      case null:
        return AppExitResponse.cancel;
    }
  }

  Future<void> _stopAndExit() async {
    await _c.target.stop();
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'idr',
      debugShowCheckedModeBanner: false,
      navigatorKey: _nav,
      theme: idrTheme(),
      navigatorObservers: [TelemetryFlutter.routeObserver],
      home: ListenableBuilder(
        listenable: _c,
        builder: (_, _) => _Gate(controller: _c),
      ),
    );
  }
}

/// Shows the screen for the SDK's readiness step ([TargetReadyStep]).
class _Gate extends StatelessWidget {
  const _Gate({required this.controller});

  final TargetController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (!c.booted) return const SplashScreen();
    return switch (c.state.readyStep) {
      SignInRequired() => SignInScreen(controller: c),
      PlanRequired() || RoleRequired() => ModeScreen(controller: c),
      BillingRequired() => BillingScreen(controller: c),
      EnterpriseSetupRequired() => FinishSetupScreen(controller: c),
      RegistrationRequired() => RegisterScreen(controller: c),
      Ready() when c.setupPending => FinishSetupScreen(controller: c),
      Ready() => HomeScreen(controller: c),
    };
  }
}
