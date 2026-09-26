import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/app_controller.dart';
import '../core/cloud_controller.dart';
import '../core/sync_diagnostics.dart';
import 'shared.dart';
import 'password_page.dart';

class AccountPanel extends StatefulWidget {
  final AppController app;
  final CloudController cloud;
  const AccountPanel({super.key, required this.app, required this.cloud});
  @override
  State<AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<AccountPanel> {
  final email = TextEditingController(), password = TextEditingController();
  bool _hideLoginPassword = true;
  String? message;
  AppController get app => widget.app;
  CloudController get cloud => widget.cloud;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  String errorText(Object error) {
    if (error is AuthException) {
      return switch (error.code) {
        'invalid_credentials' => app.text(
          '邮箱或密码不正确。',
          'Incorrect email or password.',
        ),
        'email_not_confirmed' => app.text(
          '请先完成邮箱验证码注册。',
          'Finish email-code registration first.',
        ),
        'weak_password' => app.text(
          '密码强度不足，请使用更长的密码。',
          'Use a longer, stronger password.',
        ),
        'over_email_send_rate_limit' || 'over_request_rate_limit' => app.text(
          '请求过于频繁，请稍后重试。',
          'Too many requests. Please try again later.',
        ),
        'email_address_not_authorized' => app.text(
          '测试项目暂不能向该邮箱发信，需要配置 SMTP 邮件服务。',
          'This test project needs an SMTP service to send to this address.',
        ),
        _ => authError(app, error),
      };
    }
    return app.text(
      '操作未完成，本地记录仍保留。请联网后重试。',
      'Operation incomplete. Local records are retained. Connect and retry.',
    );
  }

  Future<void> run(Future<void> Function() action, {String? success}) async {
    setState(() => message = null);
    try {
      await action();
      if (mounted) setState(() => message = success);
    } catch (e) {
      SyncDiagnostics.record('account_operation_error', {
        'error_type': e.runtimeType.toString(),
        if (e is AuthException) 'code': e.code,
        if (e is AuthException) 'http_status': e.statusCode,
        if (e is AuthException)
          'message': SyncDiagnostics.safeMessage(e.message),
      });
      if (mounted) setState(() => message = errorText(e));
    }
  }

  void passwordPage(PasswordAction action) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => PasswordPage(
        app: app,
        action: action,
        email: action == PasswordAction.change
            ? (cloud.email ?? '')
            : email.text.trim(),
      ),
    ),
  );

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(app.text('取消', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(app.text('确认', 'Confirm')),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> conflicts() async {
    final rows = await cloud.conflictRows();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(app.text('待处理的同步冲突', 'Sync conflicts')),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  app.text(
                    '计数事件不会被覆盖。以下选择只用于项目资料、排序、设置或会话信息。',
                    'Count events are never overwritten. These choices apply to project details, order, settings or sessions.',
                  ),
                ),
                for (final row in rows)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${row['entity_id']}'),
                          Text(stamp(row['created_at'])),
                          Text(app.text('本地内容', 'Local content')),
                          SelectableText('${row['local_payload']}'),
                          Text(app.text('云端内容', 'Cloud content')),
                          SelectableText('${row['remote_payload'] ?? '—'}'),
                          if (row['reason'] == 'revision_changed' &&
                              [
                                'project',
                                'setting',
                                'order',
                                'session',
                              ].contains(row['entity_type']))
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    run(
                                      () => cloud.resolve(row, keepLocal: true),
                                    );
                                  },
                                  child: Text(
                                    app.text('保留本地修改', 'Keep local changes'),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    run(
                                      () =>
                                          cloud.resolve(row, keepLocal: false),
                                    );
                                  },
                                  child: Text(
                                    app.text('采用云端内容', 'Use cloud content'),
                                  ),
                                ),
                              ],
                            )
                          else
                            Text(
                              app.text(
                                '需要检查该记录或重新选择项目图片；原始数据已保留。',
                                'This record needs review, or the project image needs replacing. Original data is retained.',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (rows.isEmpty)
                  Text(app.text('没有待处理冲突', 'No unresolved conflicts')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(app.text('关闭', 'Close')),
          ),
        ],
      ),
    );
  }

  String get status => switch (cloud.status) {
    'initializing' => app.text('正在恢复登录状态…', 'Restoring sign-in…'),
    'unavailable' => app.text(
      '云服务初始化失败，本地计数可继续。请重启应用重试。',
      'Cloud initialization failed. Local counting remains available. Restart to retry.',
    ),
    'authentication_required' => app.text(
      '登录已过期，请重新登录；离线记录仍保留。',
      'Sign in again to sync. Offline records are retained.',
    ),
    'retry_pending' => app.text(
      '等待网络恢复，应用前台将自动重试。',
      'Waiting for connectivity. Automatic retries run while the app is open.',
    ),
    'local_error' => app.text(
      '无法读取同步状态，请重启应用。',
      'Cannot read sync status. Restart the app.',
    ),
    _ =>
      cloud.userId == null
          ? app.text('访客模式 · 数据保存在此设备', 'Guest mode · Stored on this device')
          : app.text(
              '前台自动同步已启用',
              'Automatic sync enabled while the app is open',
            ),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: cloud,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.account_circle_outlined),
          title: Text(
            cloud.email ??
                app.text(
                  cloud.userId == null ? '本地使用' : '已保存的账号',
                  cloud.userId == null ? 'Local mode' : 'Saved account',
                ),
          ),
          subtitle: Text(status),
        ),
        if (cloud.userId != null) ...[
          Text(
            '${app.text('待同步', 'Pending')}: ${cloud.pending} · ${app.text('冲突', 'Conflicts')}: ${cloud.conflicts}',
          ),
          Text(
            '${app.text('最近完整同步', 'Last complete sync')}: ${stamp(cloud.lastSync)}',
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: cloud.busy ? null : () => run(cloud.syncNow),
                icon: const Icon(Icons.sync),
                label: Text(app.text('立即同步', 'Sync now')),
              ),
              OutlinedButton(
                onPressed: cloud.busy || cloud.email == null
                    ? null
                    : () => passwordPage(PasswordAction.change),
                child: Text(app.text('修改密码', 'Change password')),
              ),
              if (cloud.conflicts > 0)
                OutlinedButton(
                  onPressed: cloud.busy ? null : () => run(conflicts),
                  child: Text(app.text('处理冲突', 'Resolve conflicts')),
                ),
              OutlinedButton(
                onPressed: cloud.busy
                    ? null
                    : () async {
                        if (await confirm(
                          app.text('导入访客记录', 'Import guest records'),
                          app.text(
                            '将此设备的访客项目、图片、历史和笔记（含分类）复制到当前账号并上传。原记录保留；已认领的项目和笔记不会转给其他账号。',
                            'Copy guest projects, images, history and notes (with categories) to this account for upload. Originals remain. Claimed items cannot be imported into another account.',
                          ),
                        )) {
                          await run(
                            cloud.importGuest,
                            success: app.text(
                              '导入完成，等待同步。',
                              'Imported. Waiting to sync.',
                            ),
                          );
                        }
                      },
                child: Text(app.text('导入本地访客记录', 'Import guest records')),
              ),
              TextButton(
                onPressed: cloud.busy
                    ? null
                    : () async {
                        if (await confirm(
                          app.text('退出登录', 'Sign out'),
                          app.text(
                            '退出后显示访客数据。当前账号的离线记录留在此设备，下次登录该账号后继续同步。',
                            'Guest data will be shown. This account’s offline records remain on this device and resume syncing when you sign in again.',
                          ),
                        )) {
                          await run(cloud.signOut);
                        }
                      },
                child: Text(app.text('退出登录', 'Sign out')),
              ),
            ],
          ),
        ],
        if (cloud.userId == null ||
            cloud.status == 'authentication_required') ...[
          const SizedBox(height: 16),
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(labelText: app.text('邮箱', 'Email')),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: password,
            obscureText: _hideLoginPassword,
            enableSuggestions: false,
            autocorrect: false,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(labelText: app.text('密码', 'Password'), suffixIcon: IconButton(icon: Icon(_hideLoginPassword ? Icons.visibility_outlined : Icons.visibility_off_outlined), onPressed: () => setState(() => _hideLoginPassword = !_hideLoginPassword))),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: !cloud.ready || cloud.busy
                    ? null
                    : () => run(() async {
                        await cloud.signIn(email.text, password.text);
                        if (mounted) password.clear();
                      }),
                child: Text(app.text('登录', 'Sign in')),
              ),
              if (cloud.userId == null)
                OutlinedButton(onPressed: !cloud.ready || cloud.busy ? null : () => passwordPage(PasswordAction.register), child: Text(app.text('注册账号', 'Create account'))),
              TextButton(
                onPressed: !cloud.ready || cloud.busy
                    ? null
                    : () => passwordPage(PasswordAction.recover),
                child: Text(app.text('忘记密码', 'Forgot password')),
              ),
            ],
          ),
          Text(
            app.text(
              '登录后显示该账号的数据。注册会通过邮箱验证码完成。',
              'Signing in opens this account’s data. Registration uses an email verification code.',
            ),
          ),
        ],
        if (cloud.busy) const LinearProgressIndicator(),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              message!,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ),
      ],
    ),
  );
}

/// The single account-and-sync body shared by Settings and Common, so both
/// entries always show the same AccountPanel bound to the same CloudController.
Widget accountSyncContent(AppController app) => app.cloud != null
    ? AccountPanel(app: app, cloud: app.cloud!)
    : ListTile(title: Text(app.text('本地使用', 'Local mode')));

class AccountSyncPage extends StatelessWidget {
  final AppController app;
  const AccountSyncPage({super.key, required this.app});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(app.text('账号与同步', 'Account and sync'))),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [accountSyncContent(app)],
        ),
      ),
    ),
  );
}
