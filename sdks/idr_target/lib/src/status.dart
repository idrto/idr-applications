/// High-level Target lifecycle status.
enum IdrTargetStatus {
  initializing,
  signedOut,
  registering,
  enrolling,
  authenticating,
  securingTls,
  starting,
  running,
  reconnecting,
  needsAttention,
  stopped,
  failed,
}
