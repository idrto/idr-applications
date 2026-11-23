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

class _TargetAppState extends State<TargetApp> {
  late final TargetController _c = widget.controller ?? TargetController();

  @override
  void initState() {
    super.initState();
    _c.boot();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'idr',
      debugShowCheckedModeBanner: false,
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
