import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'local_sync_store.dart';

class SyncSnapshots {
  final LocalSyncStore store;
  SyncSnapshots(this.store);
  Future<Map<String, Object?>> build(
    DatabaseExecutor tx,
    String kind,
    String id,
  ) async {
    if (kind == 'event') return store.eventPayload(tx, id);
    if (kind == 'download') {
      final rows = await tx.query(
        'cloud_projects',
        where: 'project_id=?',
        whereArgs: [id],
      );
      return {'image_key': rows.isEmpty ? null : rows.single['image_key']};
    }
    final versions = await tx.query(
      'sync_remote_versions',
      where: 'entity_type=? AND entity_id=?',
      whereArgs: [kind, id],
    );
    final base = versions.isEmpty ? 0 : versions.single['server_revision'];
    Map<String, Object?> data;
    if (kind == 'project' || kind == 'image') {
      final p = (await tx.query(
        'projects',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      if (kind == 'image') return {'path': p['imagePath'], 'project_id': id};
      final image = await tx.query(
        'cloud_projects',
        where: 'project_id=?',
        whereArgs: [id],
      );
      final downloading = await tx.query(
        'sync_queue',
        where: "entity_type='download' AND entity_id=?",
        whereArgs: [id],
      );
      data = {
        'name': p['name'],
        'deleted_at': p['deletedAt'],
        'image_key': p['imagePath'] == null && downloading.isEmpty
            ? null
            : (image.isEmpty ? null : image.single['image_key']),
      };
    } else if (kind == 'setting') {
      final r = (await tx.query(
        'settings',
        where: 'settingKey=?',
        whereArgs: [id],
      )).single;
      data = {'value': r['value']};
    } else if (kind == 'order') {
      data = {
        'ids': (await tx.query(
          'projects',
          columns: ['id'],
          where: 'deletedAt IS NULL',
          orderBy: 'position,createdAt,id',
        )).map((p) => p['id']).toList(),
      };
    } else if (kind == 'session') {
      final r = (await tx.query(
        'sessions',
        where: 'id=?',
        whereArgs: [id],
      )).single;
      data = {
        'project_id': r['projectId'],
        'start_at': r['startAt'],
        'end_at': r['endAt'],
        'added': r['added'],
        'total_after': r['totalAfter'],
        'created_at': r['createdAt'],
        'updated_at': r['updatedAt'],
        'deleted_at': r['deletedAt'],
      };
    } else {
      throw StateError('Unknown queue type');
    }
    return {'base_revision': base, 'data': data};
  }
}

Future<void> enqueue(DatabaseExecutor tx, String kind, String id) => tx
    .rawInsert(
      '''
INSERT INTO sync_queue(entity_type,entity_id) VALUES(?,?)
ON CONFLICT(entity_type,entity_id) DO UPDATE SET generation=generation+1,
attempts=0,next_attempt_at=0,state='pending',request_id=NULL,payload=NULL,last_error=NULL
''',
      [kind, id],
    )
    .then((_) {});

Map<String, Object?> jsonMap(Object? value) => Map<String, Object?>.from(
  value is String ? jsonDecode(value) as Map : value as Map,
);
