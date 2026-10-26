import 'package:idr_session/idr_session.dart';
import '../catalog/service_selection.dart';
import '../errors.dart';
import 'ready_step.dart';

/// Immutable grouped snapshot published by [IdrSource].
class SourceState {
  const SourceState({
    required this.ready,
    this.session,
    this.fqhn,
    this.connected = false,
    this.services = const [],
    this.activeService,
    this.models = const [],
    this.activeModel,
    this.attention,
  });

  final SourceReadyStep ready;
  final IdrAuthSession? session;

  /// Last / current Target FQHN (prefs + live connection).
  final String? fqhn;

  /// Live WebRTC connection in this process only.
  final bool connected;

  final List<ServiceSelection> services;
  final String? activeService;
  final List<String> models;
  final String? activeModel;
  final SourceAttention? attention;

  SourceState copyWith({
    SourceReadyStep? ready,
    IdrAuthSession? session,
    String? fqhn,
    bool? connected,
    List<ServiceSelection>? services,
    String? activeService,
    List<String>? models,
    String? activeModel,
    SourceAttention? attention,
    bool clearSession = false,
    bool clearFqhn = false,
    bool clearActiveService = false,
    bool clearActiveModel = false,
    bool clearAttention = false,
  }) {
    return SourceState(
      ready: ready ?? this.ready,
      session: clearSession ? null : (session ?? this.session),
      fqhn: clearFqhn ? null : (fqhn ?? this.fqhn),
      connected: connected ?? this.connected,
      services: services ?? this.services,
      activeService:
          clearActiveService ? null : (activeService ?? this.activeService),
      models: models ?? this.models,
      activeModel: clearActiveModel ? null : (activeModel ?? this.activeModel),
      attention: clearAttention ? null : (attention ?? this.attention),
    );
  }
}
