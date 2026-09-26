import 'package:supabase_flutter/supabase_flutter.dart';

String? resourceLimitMessage(Object error) {
  final text = error.toString();
  const messages = {
    'RESOURCE_ACCOUNT_BANNED': '此账号已暂停使用，请联系管理员。',
    'RESOURCE_UPLOAD_PAUSED': '管理员已暂停您的上传权限，已有文件仍保留。',
    'RESOURCE_TYPE_BLOCKED': '您暂时不能上传此类文件，请联系管理员。',
    'RESOURCE_USER_QUOTA': '您的存储空间已达到限额，暂时不能上传新文件。已有文件不会被删除。',
    'RESOURCE_DAILY_LIMIT': '您今天的上传额度已用完，请明天再试。',
    'RESOURCE_MONTHLY_LIMIT': '您本月的上传额度已用完，请下月再试或联系管理员。',
  };
  for (final item in messages.entries) {
    if (text.contains(item.key) || text.contains(item.value)) return item.value;
  }
  return null;
}

Future<void> checkResourceUpload(
  SupabaseClient client,
  String name,
  int size, {
  String mime = '',
}) async {
  try {
    await client.rpc(
      'resource_upload_check',
      params: {'p_name': name, 'p_size': size, 'p_mime': mime},
    );
  } catch (e) {
    throw StateError(resourceLimitMessage(e) ?? '暂时无法确认上传额度，请联网重试。您的本地文件已保留。');
  }
}
