import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/app_controller.dart';
import '../core/cloud_controller.dart';
import '../core/sync_diagnostics.dart';
import '../domain/email_suggest.dart';
import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;

enum PasswordAction { change, recover, register }

/// Uses an isolated Auth session so recovery never switches the active ledger.
class PasswordPage extends StatefulWidget {
  final AppController app;
  final PasswordAction action;
  final String email;
  const PasswordPage({
    super.key,
    required this.app,
    required this.action,
    this.email = '',
  });
  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  final mail = TextEditingController(),
      mail2 = TextEditingController(),
      old = TextEditingController();
  final code = TextEditingController(),
      password = TextEditingController(),
      repeat = TextEditingController();
  late final SupabaseClient client;
  bool busy = false,
      verified = false,
      sent = false,
      hidePassword = true,
      hideRepeat = true,
      finishingRegistration = false;
  int seconds = 0;
  Timer? countdown;
  String? message;
  AppController get app => widget.app;
  bool get changing => widget.action == PasswordAction.change;
  bool get registering => widget.action == PasswordAction.register;
  @override
  void initState() {
    super.initState();
    mail.text = widget.email;
    client = CloudController.isolatedAuthClient();
    for (final field in [mail, mail2]) {
      field.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    countdown?.cancel();
    for (final field in [mail, mail2, old, code, password, repeat]) {
      field.dispose();
    }
    client.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } on AuthException catch (e) {
      SyncDiagnostics.record('password_flow_auth_error', {
        'code': e.code,
        'http_status': e.statusCode,
        'message': SyncDiagnostics.safeMessage(e.message),
      });
      if (mounted) setState(() => message = authError(app, e));
    } catch (e) {
      SyncDiagnostics.record('password_flow_error', {
        'error_type': e.runtimeType.toString(),
        if (e is StateError) 'state': SyncDiagnostics.safeMessage(e.message),
        if (e is AssertionError && e.message != null)
          'assertion': SyncDiagnostics.safeMessage(e.message.toString()),
        'detail': SyncDiagnostics.safeMessage(e.toString()),
      });
      final network =
          e is SocketException ||
          e is http.ClientException ||
          e is TimeoutException;
      if (mounted) {
        setState(
          () => message = network
              ? app.text(
                  '网络连接失败，请稍后重试。',
                  'Connection failed. Please retry later.',
                )
              : stateError(app, e) ??
                    app.text(
                      '操作未完成，本地数据已保留。请返回账号页重新操作。',
                      'Operation incomplete. Local data is retained. Return to the account page and retry.',
                    ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Registration: no verification code and no confirmation email. The two
  /// email fields and two password fields are the only confirmation step;
  /// beginGuestRegistration converts the current anonymous session in place
  /// (see cloud_controller.dart), which takes effect immediately as long as
  /// Supabase Auth's "Confirm email" setting is off — see the deployment
  /// notes shipped with this change for the exact dashboard toggle.
  Future<void> register() => run(() async {
    final email1 = mail.text.trim();
    final email2 = mail2.text.trim();
    if (!validEmail(email1)) {
      throw const AuthException('Invalid email', code: 'email_address_invalid');
    }
    if (!sameEmail(email1, email2)) {
      setState(
        () => message = app.text(
          '两次输入的邮箱不一致，请重新检查。',
          'The two email addresses do not match.',
        ),
      );
      return;
    }
    if (password.text.length < 8 || password.text != repeat.text) {
      setState(
        () => message = app.text(
          '密码至少 8 位，两次输入须一致。',
          'Use at least 8 characters and enter the same password twice.',
        ),
      );
      return;
    }
    await app.cloud!.beginGuestRegistration(normalizeEmail(email1), password.text);
    // updateUser() on the anonymous session normally flips is_anonymous
    // synchronously when "Confirm email" is off. Poll briefly as a safety
    // net in case of a slower round trip, or in case that dashboard setting
    // hasn't been turned off yet, in which case we tell the user why.
    if (mounted) setState(() => finishingRegistration = true);
    var confirmed = app.cloud?.client?.auth.currentUser?.isAnonymous == false;
    for (var i = 0; i < 25 && !confirmed && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      confirmed = app.cloud?.client?.auth.currentUser?.isAnonymous == false;
    }
    if (!mounted) return;
    setState(() {
      finishingRegistration = false;
      message = confirmed
          ? app.text('注册成功！可以返回上一页继续使用。', 'Registration complete! You can go back now.')
          : app.text(
              '账号已创建，但尚未确认。请检查邮箱是否收到确认邮件；如果没有，请联系管理员检查后台的“Confirm email”设置。',
              'Account created but not yet confirmed. Check your email for a confirmation link, or contact the administrator to check the "Confirm email" setting.',
            );
    });
  });

  Future<void> send() => run(() async {
    if (!validEmail(mail.text)) {
      throw const AuthException('Invalid email', code: 'email_address_invalid');
    }
    await client.auth.resetPasswordForEmail(mail.text.trim());
    if (mounted) {
      setState(() {
        message = app.text('验证码已发送，请检查邮箱。', 'Verification code sent. Check your email.');
        sent = true;
      });
      seconds = 60;
      countdown?.cancel();
      countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || seconds <= 1) {
          countdown?.cancel();
          if (mounted) setState(() => seconds = 0);
        } else {
          setState(() => seconds--);
        }
      });
    }
  });
  Future<void> submit() => run(() async {
    if (!validEmail(mail.text)) {
      throw const AuthException('Invalid email', code: 'email_address_invalid');
    }
    if (!changing &&
        (password.text.length < 8 || password.text != repeat.text)) {
      setState(
        () => message = app.text(
          '新密码至少 8 位，两次输入须一致。',
          'Use at least 8 characters and enter the same password twice.',
        ),
      );
      return;
    }
    if (!changing && code.text.trim().isEmpty) {
      setState(() => message = app.text('请输入邮箱验证码。', 'Enter the email verification code.'));
      return;
    }
    if (!verified) {
      if (changing) {
        await client.auth.signInWithPassword(
          email: mail.text.trim(),
          password: old.text,
        );
      } else {
        await client.auth.verifyOTP(
          email: mail.text.trim(),
          token: code.text.trim(),
          type: OtpType.recovery,
        );
      }
      verified = true;
    }
    await client.auth.updateUser(
      UserAttributes(
        password: password.text,
        currentPassword: changing ? old.text : null,
      ),
    );
    await client.auth.signOut(scope: SignOutScope.local);
    verified = false;
    if (mounted) {
      old.clear();
      code.clear();
      password.clear();
      repeat.clear();
      setState(
        () => message = app.text(
          '密码已更新，下次登录请使用新密码。',
          'Password updated. Use your new password next time you sign in.',
        ),
      );
    }
  });

  Widget emailField(
    TextEditingController controller, {
    required String label,
    required bool enabled,
  }) {
    final suggestions = emailDomainSuggestions(controller.text);
    final typoFix = emailTypoSuggestion(controller.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          enabled: enabled,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(labelText: label),
        ),
        if (typoFix != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              onTap: enabled
                  ? () => setState(() => controller.text = typoFix)
                  : null,
              child: Text(
                app.text('是否为 $typoFix？点击使用', 'Did you mean $typoFix? Tap to use'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          )
        else if (suggestions.isNotEmpty && enabled)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final s in suggestions)
                  ActionChip(
                    label: Text(s),
                    onPressed: () => setState(() => controller.text = s),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        registering
            ? app.text('注册账号', 'Create account')
            : changing
            ? app.text('修改密码', 'Change password')
            : app.text('忘记密码', 'Forgot password'),
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (registering)
              emailField(
                mail,
                label: app.text('邮箱', 'Email'),
                enabled: !busy && !finishingRegistration,
              )
            else
              TextField(
                controller: mail,
                enabled: !busy && !verified && !changing,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(labelText: app.text('邮箱', 'Email')),
              ),
            if (registering) ...[
              const SizedBox(height: 8),
              emailField(
                mail2,
                label: app.text('再次输入邮箱', 'Confirm email'),
                enabled: !busy && !finishingRegistration,
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  app.text(
                    '请再次确认邮箱。邮箱填写错误以后，将无法通过“忘记密码”找回账号。',
                    'Double-check your email. If it is wrong, you will not be able to recover your account with "Forgot password".',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            if (changing)
              TextField(
                controller: old,
                enabled: !busy && !verified,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: app.text('当前密码', 'Current password'),
                ),
              ),
            if (!changing && !registering) ...[
              Align(alignment: Alignment.centerRight, child: TextButton(onPressed: busy || verified || seconds > 0 ? null : send, child: Text(seconds > 0 ? '重新发送（$seconds秒）' : sent ? '重新发送验证码' : '发送验证码'))),
              TextField(
                controller: code,
                enabled: !busy && !verified,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: app.text('邮件验证码', 'Email verification code'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: password,
              enabled: !busy && !finishingRegistration,
              obscureText: hidePassword,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: app.text(registering ? '密码（至少 8 位）' : '新密码（至少 8 位）', 'Password (at least 8 characters)'), suffixIcon: IconButton(icon: Icon(hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined), onPressed: () => setState(() => hidePassword = !hidePassword)),
              ),
            ),
            TextField(
              controller: repeat,
              enabled: !busy && !finishingRegistration,
              obscureText: hideRepeat,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: app.text(registering ? '确认密码' : '确认新密码', 'Confirm password'), suffixIcon: IconButton(icon: Icon(hideRepeat ? Icons.visibility_outlined : Icons.visibility_off_outlined), onPressed: () => setState(() => hideRepeat = !hideRepeat)),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: busy || finishingRegistration
                  ? null
                  : registering
                  ? register
                  : submit,
              child: Text(
                registering
                    ? app.text('注册', 'Register')
                    : app.text('保存新密码', 'Save new password'),
              ),
            ),
            if (finishingRegistration) ...[
              const SizedBox(height: 12),
              const Center(child: CircularProgressIndicator()),
            ],
            if (busy) const LinearProgressIndicator(),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(message!),
              ),
          ],
        ),
      ),
    ),
  );
}

bool validEmail(String email) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email.trim());

String? stateError(AppController app, Object error) {
  if (error is! StateError) return null;
  return switch (error.message.toString()) {
    'AUTH_NOT_READY' || 'Chat initialization pending' => app.text(
        '认证服务仍在连接中，请稍候重试。',
        'Authentication is still connecting. Please retry shortly.',
      ),
    'GUEST_UPGRADE_REQUIRED' => app.text(
        '当前游客身份无法升级。请返回首页后重新进入注册。',
        'The current guest identity cannot be upgraded. Return home and reopen registration.',
      ),
    _ => app.text(
        '注册流程未完成：${error.message}。本地数据已保留。',
        'Registration did not complete: ${error.message}. Local data is retained.',
      ),
  };
}

String authError(
  AppController app,
  AuthException error,
) => switch (error.code) {
  'email_address_not_authorized' => app.text(
    '测试服务尚未开通向此邮箱发信，需要管理员配置邮件服务。',
    'Email delivery to this address is not configured. Contact the administrator.',
  ),
  'over_email_send_rate_limit' || 'over_request_rate_limit' => app.text(
    '发送过于频繁，请稍后再试。',
    'Too many requests. Please try later.',
  ),
  'otp_expired' || 'otp_disabled' => app.text(
    '验证码无效或已过期，请重新申请邮件。',
    'The code is invalid or expired. Request a new email.',
  ),
  'invalid_credentials' => app.text(
    '邮箱或当前密码不正确。',
    'Incorrect email or current password.',
  ),
  'email_address_invalid' || 'validation_failed' => app.text(
    '请检查邮箱和输入内容。',
    'Check your email address and input.',
  ),
  'same_password' => app.text(
    '新密码不能与原密码相同。',
    'Choose a password different from the old one.',
  ),
  'weak_password' => app.text(
    '密码强度不足，请使用更长且包含不同字符的密码。',
    'Use a longer password with a mix of characters.',
  ),
  'reauthentication_needed' || 'reauthentication_not_valid' => app.text(
    '需要重新验证身份，请返回后重试或使用忘记密码。',
    'Verification is required. Reopen this page or use Forgot password.',
  ),
  _ => app.text(
    '操作失败，请稍后重试。错误类型：${error.code ?? 'auth_error'}',
    'Please retry later. Error type: ${error.code ?? 'auth_error'}',
  ),
};
