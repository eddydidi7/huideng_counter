import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/cloud_file.dart';

class DriveUploadQueue {
  DriveUploadQueue(this.owner, {this.publicResources = false});
  final String owner;
  final bool publicResources;
  String get key => publicResources
      ? 'public_resource_upload_queue_v1_$owner'
      : 'drive_upload_queue_v1_$owner';
  Future<List<DriveUpload>> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => DriveUpload.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> save(List<DriveUpload> tasks) async {
    final ok = await (await SharedPreferences.getInstance()).setString(
      key,
      jsonEncode(tasks.map((t) => t.toJson()).toList()),
    );
    if (!ok) throw const DriveFailure('QUEUE_SAVE_FAILED');
  }
}
