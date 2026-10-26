import 'session_store.dart';
import 'user_state.dart';

/// Target-specific first-run UI state on top of shared [SessionStore].
extension TargetUserStatePersistence on SessionStore {
  Future<TargetUserState> loadUserState() async {
    final j = await readJson('user_state');
    return TargetUserState.fromJson(j);
  }

  Future<void> saveUserState(TargetUserState state) =>
      writeJson('user_state', state.toJson());

  Future<void> clearUserState() => deleteSecret('user_state');
}
