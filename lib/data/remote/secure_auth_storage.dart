import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SecureAuthStorage extends LocalStorage {
  static const vault = FlutterSecureStorage();
  static const key = 'huideng.supabase.session.v1';
  const SecureAuthStorage();
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => (await accessToken()) != null;
  @override
  Future<String?> accessToken() => vault.read(key: key);
  @override
  Future<void> persistSession(String session) =>
      vault.write(key: key, value: session);
  @override
  Future<void> removePersistedSession() => vault.delete(key: key);
}
