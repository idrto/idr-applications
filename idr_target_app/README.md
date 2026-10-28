# idr_target_app

Desktop GUI for the IDR Target. It drives the same `package:idr_target` SDK as the `idrt` CLI
(`../idr_target_cli`) and follows the CLI's workflows: sign-in, mode setup
(Personal / Enterprise / Service Provider), billing gate, host registration, approvals,
services, custom domains (CNAME + Let's Encrypt), enterprise zones/members/devices.

- `lib/target/` SDK glue: env/config (same variables as `idrt`) and `TargetController`.
- `lib/screens/` pre-home flow (sign-in, mode, billing, register) and the home sections.
- `lib/ui/` copied design-system widgets (no dependency on `idr_ui_views`).

Run: `flutter run -d windows`. Needs billing, Presence, `target-agent` and `idr_dp`
(see `../idr_target_cli/README.md`). Tests: `flutter test`.
