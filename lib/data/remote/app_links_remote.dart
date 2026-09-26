import 'package:supabase_flutter/supabase_flutter.dart';

class AppLinksRemote {
  final SupabaseClient client;
  AppLinksRemote(this.client);
  Future<Map<String, dynamic>?> fetch() => client
      .from('app_links')
      .select()
      .eq('id', 'global')
      .maybeSingle()
      .timeout(const Duration(seconds: 10));
}
