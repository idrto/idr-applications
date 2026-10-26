import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import 'core/billing.dart';
import 'core/commands.dart';
import 'core/doctor.dart';
import 'menu.dart';
import 'modes/enterprise.dart';
import 'modes/personal.dart';
import 'modes/provider.dart';

const idrtVersion = '0.2.0';

Future<int> runIdrtCli(List<String> args) => (CliRunner(
      'idrt',
      'IDR Target: serve local services to approved Sources, and administer '
          'devices (Personal / Enterprise / Service Provider).',
      version: idrtVersion,
      home: idrtMenu,
      homeAfter: const {
        'login',
        'personal setup',
        'enterprise setup',
        'provider setup',
        'personal register',
        'enterprise register',
        'provider register',
      },
    )
          // Shared core
          ..addCommand(LoginCommand())
          ..addCommand(LogoutCommand())
          ..addCommand(StatusCommand())
          ..addCommand(StartCommand())
          ..addCommand(ServicesCommand())
          ..addCommand(BillingCommand())
          ..addCommand(SubscribeCommand())
          ..addCommand(DoctorCommand())
          // Modes
          ..addCommand(PersonalCommand())
          ..addCommand(EnterpriseCommand())
          ..addCommand(ProviderCommand()))
        .execute(args, translate: translateTargetError);

/// SDK errors → exit code + hint.
CliError? translateTargetError(Object e) => switch (e) {
      IdrTargetException(:final code, :final message) => CliError(
          billingAttentionCodes.contains(code)
              ? CliExit.billing
              : code == IdrTargetErrorCode.authRequired
                  ? CliExit.auth
                  : CliExit.failure,
          message,
          hint: billingAttentionCodes.contains(code)
              ? 'Run `idrt billing`.'
              : null,
          code: code.wire,
        ),
      StateError(:final message) when message.contains('sign in first') =>
        CliError(CliExit.auth, 'Not signed in.',
            hint: 'Run `idrt login`.', code: 'AUTH_REQUIRED'),
      StateError(:final message) when message.contains('binary not found') =>
        CliError(CliExit.config, message,
            hint: 'Build target-agent and set IDR_TARGET_AGENT, or put it '
                'next to idrt or on PATH (`idrt doctor`).',
            code: 'AGENT_MISSING'),
      StateError(:final message) => CliError(CliExit.failure, message),
      _ when '$e'.contains('ClientException') => CliError(
          CliExit.connect, 'Network error: $e',
          hint: 'Run `idrt doctor`.', code: 'NETWORK'),
      _ => null,
    };
