/// TLS leaf / edge status for the Target.
enum IdrTlsStatus {
  /// Phase 1 native `*.idr.to` — Relay terminates; no Target leaf needed.
  relayTerminated,
  notRequired,
  pending,
  issuing,
  ready,
  renewing,
  needsAttention,
}
