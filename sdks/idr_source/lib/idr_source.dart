/// Production Source SDK — billing SSO, Presence/WebRTC, Target services.
library idr_source;

export 'package:two_key_dart_sdk/two_key_headless.dart'
    show
        BillingAuthClient,
        BillingAuthStorage,
        DelegatePermissionsClient,
        LoopbackAuthSessionLauncher,
        SecureBillingAuthStorage;

export 'package:idr_service_http/idr_service_http.dart' show ChatTurn;
export 'package:idr_session/idr_session.dart'
    show FileAuthStorage, IdrAuthSession, IdrFlavor, idrSourceDirectory;

export 'src/catalog/service_selection.dart';
export 'src/config.dart';
export 'src/errors.dart';
export 'src/identity/source_identity_manager.dart' show SourceIdentityManager;
export 'src/idr_source.dart';
export 'src/library_path.dart';
export 'src/prefs/source_prefs.dart';
export 'src/state/ready_step.dart';
export 'src/state/source_state.dart';
