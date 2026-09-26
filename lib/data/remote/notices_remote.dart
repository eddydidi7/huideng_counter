import 'package:supabase_flutter/supabase_flutter.dart';

class NoticesRemote {
  final SupabaseClient client;
  NoticesRemote(this.client);
  Future<Map<String, dynamic>> fetch() async {
    final rows = await client
        .from('app_notices')
        .select(
          'id,title_zh,title_en,body_zh,body_en,is_pinned,published_at,updated_at,notice_type,group_id,release_version_code',
        )
        .eq('is_published', true)
        .order('is_pinned', ascending: false)
        .order('published_at', ascending: false)
        .order('id')
        .limit(100)
        .timeout(const Duration(seconds: 10));
    return {'items': rows};
  }
}
