import 'package:flutter/material.dart';
import 'package:idr_target/idr_target.dart';

import 'screens/flow_screens.dart';
import 'screens/home/home_screen.dart';
import 'target/target_controller.dart';
import 'ui/theme/idr_theme.dart';

/// `--flavor dev|staging|prod` picks `config/<name>.json`; without it a
/// release build is prod and `flutter run` is dev ([IdrFlavor.defaultName]).
void main(List<String> args) {
  IdrFlavor.init(args);
  runApp(const TargetApp());
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
      title: 'idrt',
      debugShowCheckedModeBanner: false,
      theme: idrTheme(),
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
