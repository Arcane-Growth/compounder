import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage for the gateway API key.
///
/// The key is a bearer credential, so production uses the platform keystore
/// ([SecureSecretStore]). Tests and any environment without the plugin fall
/// back to [PrefsSecretStore], which keeps the same interface.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Key under which the gateway API key is stored.
const String gatewayApiKeySecret = 'gatewayApiKey';

/// Android Keystore / iOS Keychain backed storage.
class SecureSecretStore implements SecretStore {
  final FlutterSecureStorage _storage;

  SecureSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// SharedPreferences fallback. Used by tests (no platform channel) and as a
/// safety net if the keystore is unavailable on a device.
class PrefsSecretStore implements SecretStore {
  final SharedPreferences prefs;
  const PrefsSecretStore(this.prefs);

  @override
  Future<String?> read(String key) async => prefs.getString(key);

  @override
  Future<void> write(String key, String value) async {
    await prefs.setString(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await prefs.remove(key);
  }
}
