import 'dart:convert';

import 'package:http/http.dart' as http;
import '../auth/auth.dart';
import '../errors.dart';
import '../plan/business_plan.dart';

/// Covering commercial subscription from Billing (server is source of truth).
class CoveringSubscription {
  const CoveringSubscription({required this.planCode});

  final String planCode;
}

/// Subscription hydrate + checkout against Billing HTTP.
class BillingCommerceClient {
  BillingCommerceClient({
    required this.apiBaseUrl,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String apiBaseUrl;
  final http.Client _http;

  String get _base => apiBaseUrl.replaceAll(RegExp(r'/$'), '');

  static const coveringPlanCodes = {
    'idr_personal_bundle',
    'idr_enterprise_bundle',
    'idr_sp_target',
  };

  Future<CoveringSubscription?> fetchCovering(IdrAuthSession session) async {
    final uri = Uri.parse('$_base/api/v1/subscriptions').replace(
      queryParameters: {'status': 'active', 'limit': '50'},
    );
    final res = await _http.get(uri, headers: BaHeaders.forSession(session));
    // 403 = signed in, but this org role cannot see billing (org `member`).
    // Not an expired session: never sign the user out for it. Ask only
    // whether the org is covered (the owner may already have paid).
    if (res.statusCode == 403) return _fetchOrgCoverage(session);
    if (res.statusCode == 401) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.authExpired,
        message: IdrTargetErrorMessages.authExpired,
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw IdrTargetException(
        code: IdrTargetErrorCode.billingUnavailable,
        message: IdrTargetErrorMessages.billingUnavailable,
      );
    }
    final decoded = jsonDecode(res.body);
    final rows = _rows(decoded);
    for (final row in rows) {
      final status = (row['subscriptionStatus'] as String? ?? '').toLowerCase();
      if (status != 'active') continue;
      final plan = row['plan'];
      final name = plan is Map ? plan['name'] as String? : null;
      final code = planCodeFromPlanName(name);
      if (code != null) return CoveringSubscription(planCode: code);
    }
    return null;
  }

  /// Active plan names of the org, readable by any member. Older billing
  /// without the route (404) or any other failure: not covered.
  Future<CoveringSubscription?> _fetchOrgCoverage(
    IdrAuthSession session,
  ) async {
    final res = await _http.get(
      Uri.parse('$_base/api/v1/subscriptions/coverage'),
      headers: BaHeaders.forSession(session),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final data = (jsonDecode(res.body) as Map)['data'];
    final plans = data is Map ? data['plans'] : null;
    for (final name in plans is List ? plans : const []) {
      final code = planCodeFromPlanName(name as String?);
      if (code != null) return CoveringSubscription(planCode: code);
    }
    return null;
  }

  Future<({String url, String sessionId})> createCheckoutSession({
    required IdrAuthSession session,
    required String planCode,
    String? successUrl,
    String? cancelUrl,
  }) async {
    final catalog = await _resolvePlanPricing(planCode);
    final body = <String, dynamic>{
      'planId': catalog.planId,
      'pricingId': catalog.pricingId,
      if (successUrl != null) 'successUrl': successUrl,
      if (cancelUrl != null) 'cancelUrl': cancelUrl,
    };
    final res = await _http.post(
      Uri.parse('$_base/api/v1/checkout/checkout-session'),
      headers: BaHeaders.forSession(session, jsonBody: true),
      body: jsonEncode(body),
    );
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.authExpired,
        message: IdrTargetErrorMessages.authExpired,
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw IdrTargetException(
        code: IdrTargetErrorCode.billingUnavailable,
        message: IdrTargetErrorMessages.billingUnavailable,
      );
    }
    final data = _dataMap(jsonDecode(res.body));
    final url = data['url'] as String?;
    final sessionId = data['sessionId'] as String? ?? '';
    if (url == null || url.isEmpty) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.billingUnavailable,
        message: IdrTargetErrorMessages.billingUnavailable,
      );
    }
    return (url: url, sessionId: sessionId);
  }

  /// Create the Billing subscription from a paid Stripe session (webhook fallback).
  Future<void> fulfillCheckout({
    required IdrAuthSession session,
    required String sessionId,
  }) async {
    final res = await _http.post(
      Uri.parse('$_base/api/v1/checkout/fulfill'),
      headers: BaHeaders.forSession(session, jsonBody: true),
      body: jsonEncode({'sessionId': sessionId}),
    );
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.authExpired,
        message: IdrTargetErrorMessages.authExpired,
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw IdrTargetException(
        code: IdrTargetErrorCode.billingUnavailable,
        message: IdrTargetErrorMessages.billingUnavailable,
      );
    }
  }

  Future<({String planId, String pricingId})> _resolvePlanPricing(
    String planCode,
  ) async {
    final plansRes = await _http.get(Uri.parse('$_base/api/v1/plans?limit=50'));
    if (plansRes.statusCode < 200 || plansRes.statusCode >= 300) {
      throw IdrTargetException(
        code: IdrTargetErrorCode.billingUnavailable,
        message: IdrTargetErrorMessages.billingUnavailable,
      );
    }
    String? planId;
    for (final row in _rows(jsonDecode(plansRes.body))) {
      if (_rowMatchesPlanCode(row, planCode)) {
        planId = row['id']?.toString();
        break;
      }
    }
    if (planId == null) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.billingRequired,
        message: IdrTargetErrorMessages.billingRequired,
      );
    }
    final pricesRes = await _http.get(
      Uri.parse('$_base/api/v1/plans/$planId/pricings?limit=20'),
    );
    if (pricesRes.statusCode < 200 || pricesRes.statusCode >= 300) {
      throw IdrTargetException(
        code: IdrTargetErrorCode.billingUnavailable,
        message: IdrTargetErrorMessages.billingUnavailable,
      );
    }
    final prices = _rows(jsonDecode(pricesRes.body));
    Map<String, dynamic>? annual;
    for (final p in prices) {
      if ((p['billingInterval'] as String?) == 'annual') {
        annual = p;
        break;
      }
    }
    final chosen = annual ?? (prices.isNotEmpty ? prices.first : null);
    final pricingId = chosen?['id']?.toString();
    if (pricingId == null) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.billingUnavailable,
        message: IdrTargetErrorMessages.billingUnavailable,
      );
    }
    return (planId: planId, pricingId: pricingId);
  }

  static bool _rowMatchesPlanCode(
    Map<String, dynamic> row,
    String planCode,
  ) {
    final features = row['featuresJson'];
    final fromFeatures = features is Map
        ? (features['planCode'] as String? ?? features['addonCode'] as String?)
        : null;
    return fromFeatures == planCode ||
        planCodeFromPlanName(row['name'] as String?) == planCode;
  }

  static String? planCodeFromPlanName(String? name) {
    final n = (name ?? '').toLowerCase();
    if (n.contains('personal')) return IdrBusinessPlan.personal.planCode;
    if (n.contains('enterprise')) return IdrBusinessPlan.enterprise.planCode;
    if (n.contains('service provider')) {
      return IdrBusinessPlan.serviceProvider.planCode;
    }
    return IdrBusinessPlan.fromPlanCode(name)?.planCode;
  }

  static List<Map<String, dynamic>> _rows(Object? decoded) {
    if (decoded is! Map) return const [];
    final data = decoded['data'];
    if (data is List) {
      return [
        for (final e in data)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    }
    return const [];
  }

  static Map<String, dynamic> _dataMap(Object? decoded) {
    if (decoded is Map && decoded['data'] is Map) {
      return Map<String, dynamic>.from(decoded['data'] as Map);
    }
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return {};
  }
}
