import '../auth/auth.dart';

import '../auth/user_state.dart';
import '../errors/attention.dart';
import '../registration/registration.dart';
import '../services/service_entry.dart';
import '../status.dart';
import '../tls/tls_status.dart';
import 'agent_runtime_status.dart';
import 'enrollment_snapshot.dart';
import 'ready_step.dart';

/// Immutable grouped snapshot published by [IdrTarget].
class TargetState {
  const TargetState({
    required this.status,
    required this.readyStep,
    this.attention,
    this.session,
    this.loginOptions,
    required this.user,
    this.registration,
    this.enrollment = const EnrollmentSnapshot(),
    required this.tls,
    this.services = const [],
    this.agent = AgentRuntimeStatus.stopped,
  });

  final IdrTargetStatus status;
  final TargetReadyStep readyStep;
  final IdrTargetAttention? attention;
  final IdrAuthSession? session;
  final IdrLoginOptions? loginOptions;
  final TargetUserState user;
  final IdrTargetRegistration? registration;
  final EnrollmentSnapshot enrollment;
  final IdrTlsStatus tls;
  final List<IdrServiceEntry> services;
  final AgentRuntimeStatus agent;
}
