/// Product readiness gate for Source: sign-in → connect → active service.
sealed class SourceReadyStep {
  const SourceReadyStep();
}

final class SignedOut extends SourceReadyStep {
  const SignedOut();
}

final class SignedIn extends SourceReadyStep {
  const SignedIn();
}

final class Connected extends SourceReadyStep {
  const Connected();
}

final class ServiceActive extends SourceReadyStep {
  const ServiceActive();
}
