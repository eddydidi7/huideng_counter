import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'chat_remote.dart';

class ChatLive extends ChangeNotifier {
  final ChatRemote remote;
  final String deviceId = const Uuid().v4();
  Set<String> online = {};
  Map<String, dynamic> peers = {};
  List<Map<String, dynamic>> offers = [];
  bool known = false;
  bool _closed = false;
  Timer? _freshness;
  bool invisible;
  Future<void> _presenceTail = Future<void>.value();
  ChatLive(this.remote, {this.invisible = false}) {
    if (remote.client.auth.currentUser?.isAnonymous == true) invisible = false;
  }
  Future<void> _serialize(Future<void> Function() action) {
    final next = _presenceTail.then((_) => action());
    _presenceTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> setInvisible(bool value) {
    if (value && remote.client.auth.currentUser?.isAnonymous == true) {
      return Future.error(StateError('CHAT_REGISTRATION_REQUIRED'));
    }
    invisible = value;
    if (!_closed) notifyListeners();
    return _serialize(() async {
      if (value) {
        await call('offline');
      } else {
        await _heartbeat(const []);
      }
    });
  }

  Future<dynamic> call(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    remote.checkUser();
    final value = await remote.client
        .rpc(
          'chat_live_v1',
          params: {
            'p_action': action,
            'p_data': {'device_id': deviceId, ...data},
          },
        )
        .timeout(const Duration(seconds: 15));
    remote.checkUser();
    return value;
  }

  Future<void> heartbeat(Iterable<String> users) =>
      _serialize(() => _heartbeat(users));

  Future<dynamic> transferCall(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    remote.checkUser();
    final result = await remote.client
        .rpc(
          'chat_transfer_v2',
          params: {
            'p_action': action,
            'p_data': {'device_id': deviceId, ...data},
          },
        )
        .timeout(const Duration(seconds: 15));
    remote.checkUser();
    return result;
  }

  Future<void> _heartbeat(Iterable<String> users) async {
    if (_closed) return;
    if (remote.client.auth.currentUser?.isAnonymous == true) invisible = false;
    try {
      final result = await call(invisible ? 'status' : 'heartbeat', {
        'users': users.toSet().take(300).toList(),
      });
      if (_closed) return;
      online = Set<String>.from(result['online']);
      peers = Map<String, dynamic>.from(result['peers']);
      offers = (result['offers'] as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      known = true;
      _freshness?.cancel();
      _freshness = Timer(const Duration(seconds: 45), () {
        if (!_closed) {
          known = false;
          notifyListeners();
        }
      });
      notifyListeners();
    } catch (_) {
      if (!_closed) {
        known = false;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> offline() async {
    known = false;
    if (!_closed) notifyListeners();
    try {
      await _serialize(() async {
        await call('offline');
      });
    } catch (e) {
      debugPrint('Chat presence offline: ${e.runtimeType}');
    }
  }

  @override
  void dispose() {
    _closed = true;
    _freshness?.cancel();
    unawaited(offline());
    super.dispose();
  }
}

class OnlineName extends StatelessWidget {
  final String name;
  final bool? online;
  final bool english;
  const OnlineName({
    super.key,
    required this.name,
    required this.online,
    this.english = false,
  });
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      const SizedBox(width: 6),
      Tooltip(
        message: online == null
            ? (english ? 'Status unavailable' : '状态未知')
            : online!
            ? (english ? 'Online' : '在线')
            : (english ? 'Offline' : '离线'),
        child: PresenceLamp(lit: online == true),
      ),
    ],
  );
}

/// No red indicator: an offline/unknown user has an unlit neutral lamp.
class PresenceLamp extends StatelessWidget {
  const PresenceLamp({super.key, required this.lit});
  final bool lit;
  @override
  Widget build(BuildContext context) => Container(
    width: 11,
    height: 11,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: lit
          ? const Color(0xff25d86d)
          : Theme.of(context).colorScheme.outlineVariant,
      border: Border.all(
        color: Theme.of(context).colorScheme.surface,
        width: 1,
      ),
      boxShadow: lit
          ? [
              const BoxShadow(
                color: Color(0x8025d86d),
                blurRadius: 5,
                spreadRadius: 1,
              ),
            ]
          : null,
    ),
  );
}
