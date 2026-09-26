import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/sync_diagnostics.dart';
import '../sync/notes_sync.dart';

class SupabaseNotesGateway implements NotesGateway {
  final SupabaseClient client;
  final String userId;
  SupabaseNotesGateway(this.client, this.userId);
  Future<void> ensureSession() async {
    final session = client.auth.currentSession;
    if (session == null || session.user.id != userId) {
      throw const NoteSyncFailure('waiting_login');
    }
    if (session.isExpired) {
      await client.auth.refreshSession().timeout(const Duration(seconds: 20));
    }
    if (client.auth.currentSession == null ||
        client.auth.currentSession!.isExpired ||
        client.auth.currentUser?.id != userId) {
      throw const NoteSyncFailure('waiting_login');
    }
  }

  Future<dynamic> request(String rpc, Map<String, dynamic> params) async {
    try {
      await ensureSession();
      final result = await client.rpc(rpc, params: params);
      if (client.auth.currentUser?.id != userId) {
        throw const NoteSyncFailure('waiting_login');
      }
      return result;
    } on PostgrestException catch (e) {
      final status = SyncDiagnostics.httpStatuses['/rest/v1/rpc/$rpc'];
      final category =
          status == 401 || ['PGRST301', 'PGRST302', 'PGRST303'].contains(e.code)
          ? 'waiting_login'
          : status == 403 || e.code == '42501'
          ? 'server_denied'
          : status == 400 ||
                e.code == '23502' ||
                e.code == '22P02' ||
                e.code == 'P0001'
          ? 'invalid_data'
          : 'failed';
      throw NoteSyncFailure(
        category,
        code: e.code,
        message: SyncDiagnostics.safeMessage(e.message),
        httpStatus: status,
      );
    } on AuthException catch (e) {
      throw NoteSyncFailure(
        'waiting_login',
        code: e.code,
        message: SyncDiagnostics.safeMessage(e.message),
        httpStatus: int.tryParse(e.statusCode ?? ''),
      );
    } on SocketException {
      throw const NoteSyncFailure('waiting_network');
    } on http.ClientException {
      throw const NoteSyncFailure('waiting_network');
    } on TimeoutException {
      throw const NoteSyncFailure('waiting_network');
    }
  }

  @override
  Future<Map<String, dynamic>> push(Map<String, dynamic> value) async {
    final payload = {
      for (final e in value.entries)
        if (e.key.startsWith('p_')) e.key: e.value,
    };
    if (((payload['p_data'] as Map)['body'] as String).length < 100000) {
      return Map<String, dynamic>.from(await request('sync_note_v1', payload));
    }
    final encoded = await compute(encodeNotesTransport, payload);
    var ordinal = 0;
    for (var start = 0; start < encoded.length;) {
      var end = (start + 131072).clamp(start, encoded.length);
      if (end < encoded.length &&
          encoded.codeUnitAt(end - 1) >= 0xd800 &&
          encoded.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
      await request('note_transfer_v2', {
        'p_action': 'part',
        'p_request': value['p_request'],
        'p_part': ordinal++,
        'p_content': encoded.substring(start, end),
      });
      start = end;
    }
    final finished = await request('note_transfer_v2', {
      'p_action': 'finish',
      'p_request': value['p_request'],
      'p_part': ordinal,
    });
    final pieces = <String>[];
    for (var i = 0; i < (finished['parts'] as num).toInt(); i++) {
      final part = await request('note_transfer_v2', {
        'p_action': 'result',
        'p_request': value['p_request'],
        'p_part': i,
      });
      pieces.add(part['content'] as String);
    }
    return await compute(decodeNotesTransport, pieces.join());
  }

  @override
  Future<List<Map<String, dynamic>>> pull(int cursor) async {
    final heads =
        await request('pull_note_heads_v2', {'p_after': cursor}) as List;
    final rows = <Map<String, dynamic>>[];
    for (final head in heads) {
      final pieces = <String>[];
      var count = 1;
      for (var i = 0; i < count; i++) {
        final result = await request('pull_note_part_v2', {
          'p_id': head['id'],
          'p_revision': head['revision'],
          'p_part': i,
        });
        count = (result['parts'] as num).toInt();
        pieces.add(result['content'] as String);
      }
      rows.add(await compute(decodeNotesTransport, pieces.join()));
    }
    return rows;
  }
}

String encodeNotesTransport(Map<String, dynamic> value) => jsonEncode(value);
Map<String, dynamic> decodeNotesTransport(String value) =>
    Map<String, dynamic>.from(jsonDecode(value));
