/// Production-ready Target Agent facade for IDR.
///
/// Manages SSO, entity/host registration (API-verified FQHN), DP entitlement
/// JWT, phased TLS, and `target-agent` lifecycle. Developers observe
/// [IdrTargetStatus] / [IdrTargetAttention] instead of handling routine errors.
library idr_target;

export 'package:two_key_dart_sdk/two_key_headless.dart'
    show
        BillingAuthClient,
        BillingAuthException,
        BillingAuthStorage,
        OrgInvitation,
        OrgMember,
        LoopbackAuthSessionLauncher,
        SecureBillingAuthStorage;

export 'src/auth/auth.dart';
export 'src/auth/user_state.dart';
export 'src/config.dart';
export 'src/crypto/idr_crypto.dart';
export 'src/crypto/dp/idr_dp_crypto.dart';
export 'src/enterprise/enterprise_fqhn.dart';
export 'src/enterprise/enterprise_org_manager.dart';
export 'src/enterprise/enterprise_org_models.dart';
export 'src/enterprise/enterprise_org_store.dart';
export 'src/errors/errors.dart';
export 'src/idr_target.dart';
export 'src/plan/business_plan.dart';
export 'src/plan/role_availability.dart';
export 'src/registration/custom_domain_client.dart'
    show AcmeDomainStatus, CustomDomain, CustomDomainException;
export 'src/registration/enrollment_models.dart';
export 'src/registration/registration.dart';
export 'src/services/exposable_services.dart';
export 'src/services/port_scanner.dart';
export 'src/services/scan_hit.dart';
export 'src/services/service_entry.dart';
export 'src/services/service_presets.dart';
export 'src/services/services_manager.dart';
export 'src/state/agent_runtime_status.dart';
export 'src/state/enrollment_snapshot.dart';
export 'src/state/ready_step.dart';
export 'src/state/target_state.dart';
export 'src/status.dart';
export 'src/tls/tls_status.dart';
export 'src/tls/terminator.dart';
export 'src/transfer/target_transfers.dart';
