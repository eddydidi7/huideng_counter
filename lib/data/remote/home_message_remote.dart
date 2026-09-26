import 'package:supabase_flutter/supabase_flutter.dart';

class HomeMessageRemote {
  final SupabaseClient client;
  HomeMessageRemote(this.client);

  Future<Map<String, dynamic>?> fetch() => client
      .from('home_messages')
      .select('body_zh, body_en, source_zh, source_en, updated_at')
      .eq('id', 'home')
      .eq('is_published', true)
      .maybeSingle()
      .timeout(const Duration(seconds: 10));
}
