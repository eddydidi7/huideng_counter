import 'package:flutter/services.dart';
import 'resource_image_preview.dart';
import 'windows_display.dart';
import '../services/resource_upload_policy.dart';
import '../services/apk_files.dart';
import 'apk_file_card.dart';
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:uuid/uuid.dart';
import '../data/local/drive_upload_queue.dart';
import '../data/remote/public_resource_api.dart';
import '../domain/cloud_file.dart';
import '../domain/public_resource.dart';

class PublicResourcesPage extends StatefulWidget {
  const PublicResourcesPage({
    super.key,
    required this.translate,
    required this.createApi,
    required this.settingsPage,
    this.onShare,
    this.onSaveToGroup,
    this.initialResourceId,
  });
  final String Function(String, String) translate;
  final ResourceLibraryApi? Function() createApi;
  final Widget settingsPage;
  final String? initialResourceId;
  final Future<void> Function(PublicResource)? onShare;
  final Future<void> Function(PublicResource)? onSaveToGroup;
  @override
  State<PublicResourcesPage> createState() => _PublicResourcesPageState();
}

class _PublicResourcesPageState extends State<PublicResourcesPage>
    with WidgetsBindingObserver {
  ResourceLibraryApi? api;
  DriveUploadQueue? queue;
  ResourcePolicy policy = const ResourcePolicy();
  List<PublicResource> files = [];
  List<DriveUpload> tasks = [];
  final search = TextEditingController();
  String sort = 'time', category = '';
  String? cursor, error, activity;
  bool mine = false, loading = false, busy = false;
  double progress = 0;
  DateTime lastProgress = DateTime(2000);
  Timer? configTimer;
  String tr(String zh, String en) => widget.translate(zh, en);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(connect());
    configTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!busy &&
          !loading &&
          (ModalRoute.of(context)?.isCurrent ?? false) &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(refresh());
      }
    });
  }

  Future<void> connect() async {
    api?.close();
    api = widget.createApi();
    if (api == null) return;
    queue = DriveUploadQueue(api!.owner, publicResources: true);
    try {
      tasks = await queue!.read();
      api!.guard();
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    }
    if (mounted) {
      await refresh();
      if (widget.initialResourceId != null) await resolveReference();
    }
  }

  Future<void> resolveReference() async {
    try {
      String? next;
      PublicResource? match;
      do {
        final page = await api!.list(cursor: next);
        api!.guard();
        policy = page.policy;
        match = page.files
            .where((f) => f.id == widget.initialResourceId)
            .firstOrNull;
        next = page.nextCursor;
      } while (match == null && next != null && mounted);
      if (!mounted) return;
      if (match == null) throw const DriveFailure('FILE_UNAVAILABLE');
      final file = match;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(file.name),
          content: Text('${file.description}\n${bytes(file.size)}'),
          actions: [
            IconButton(
              tooltip: tr('网盘信息', 'Drive information'),
              icon: const Icon(Icons.info_outline),
              onPressed: () => showDialog(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text(tr('网盘信息', 'Drive information')),
                  content: Text(
                    '${policy.notice}\n${tr('公共空间', 'Shared space')}: ${bytes(policy.usedBytes)} / ${bytes(policy.totalBytes)}\n${tr('单文件上限', 'File limit')}: ${bytes(policy.maxFileBytes)}',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: Text(tr('完成', 'Done')),
                    ),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
            if (policy.canDownload)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  download(file);
                },
                child: const Text('下载并打开'),
              ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy && !loading) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    configTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    api?.close();
    search.dispose();
    super.dispose();
  }

  String message(Object e) {
    final limit = resourceLimitMessage(e);
    if (limit != null) return limit;
    final code = e is DriveFailure ? e.code : '';
    return switch (code) {
      'LOGIN_REQUIRED' => tr(
        '游客身份尚未就绪，请检查网络后重新打开公共网盘。',
        'Guest identity is not ready. Check the network and reopen the library.',
      ),
      'RESOURCE_NOT_CONFIGURED' || 'RESOURCE_DISABLED' => tr(
        '公共资源正在准备中，请稍后再来。',
        'The shared library is being prepared. Please check back later.',
      ),
      'UPLOAD_DISABLED' => tr(
        '管理员已暂停上传，您仍可浏览已公开的资料。',
        'Uploads are paused. Published resources remain available.',
      ),
      'DOWNLOAD_DISABLED' => tr(
        '下载暂时暂停，请稍后再试。',
        'Downloads are paused. Please try later.',
      ),
      'RESOURCE_QUOTA_EXCEEDED' => tr(
        '共享空间或今日上传额度不足，请稍后再试或联系管理员。',
        'Shared storage or today’s upload allowance is insufficient. Try later or contact the administrator.',
      ),
      'DOWNLOAD_LIMIT' || 'RESOURCE_RATE_LIMIT' => tr(
        '已达到当前使用限额，请稍后再试。',
        'The current usage limit has been reached. Try later.',
      ),
      'UPLOAD_BUSY' => tr(
        '上次上传仍在处理中，请约5分钟后重试；本地文件已保留。',
        'Previous upload is still processing. Retry in about five minutes.',
      ),
      'UPLOAD_CONFLICT' => tr(
        '上传记录与本地文件不一致，请重新选择文件。',
        'Upload record differs from this file. Select it again.',
      ),
      'VERIFY_FAILED' => tr(
        '文件完整性校验未通过，请重试上传。',
        'File verification failed. Retry the upload.',
      ),
      'UPLOAD_NOT_COMPLETE' => tr(
        '上传尚未完成，请重试。',
        'Upload is not complete. Please retry.',
      ),
      'UPLOAD_AUTH_FAILED' => tr(
        '上传凭证校验失败，请重试；若持续失败请更新App或联系管理员。本地文件已保留。',
        'Upload authorization failed. Retry, update the app or contact the administrator. Your local file is preserved.',
      ),
      'UPLOAD_PERMISSION_DENIED' => tr(
        '没有上传权限，请联系管理员。本地文件已保留。',
        'Upload permission denied. Your local file is preserved.',
      ),
      'RESOURCE_SERVER_UNAVAILABLE' => tr(
        '服务器暂时不可用，请稍后重试。本地文件已保留。',
        'Server unavailable. Retry later; your local file is preserved.',
      ),
      'UPLOAD_TIMEOUT' => tr(
        '上传请求超时，请重试继续上传。本地文件已保留。',
        'Upload timed out. Retry to continue; your local file is preserved.',
      ),
      'NETWORK_FAILED' => tr(
        '网络连接失败，请联网后重试。本地文件已保留。',
        'Network connection failed. Reconnect and retry; your local file is preserved.',
      ),
      'FILE_TOO_LARGE' => tr(
        '文件超过当前单文件上传限制。',
        'The file exceeds the current upload size limit.',
      ),
      'FILE_TYPE_NOT_ALLOWED' => tr(
        '暂不支持上传此类文件。',
        'This file type is not allowed.',
      ),
      'FILE_UNAVAILABLE' => tr(
        '这份资料尚未公开或已下架，请刷新列表。',
        'This resource is not published or was removed. Refresh the list.',
      ),
      'LOCAL_FILE_MISSING' || 'LOCAL_FILE_CHANGED' => tr(
        '本地文件已移动或改变，请重新选择。',
        'The local file was moved or changed. Select it again.',
      ),
      'CHECKSUM_FAILED' => tr(
        '文件校验失败，未打开文件，请重新下载。',
        'Verification failed. The file was not opened; download again.',
      ),
      'FORBIDDEN' => tr(
        '没有操作权限，或管理员已关闭上传者删除权限。请刷新列表后重试。',
        'Permission denied, or uploader deletion is disabled. Refresh and retry.',
      ),
      'UPDATE_REQUIRED' => tr(
        '此功能需要更新App后使用。',
        'Update the app to use this feature.',
      ),
      _ => tr(
        '上传或服务请求未完成，请重试；若持续失败请联系管理员。本地原文件保留。',
        'The request failed. Retry or contact the administrator if it persists. Your original file is preserved.',
      ),
    };
  }

  Future<void> refresh({bool more = false}) async {
    if (api == null || loading || !mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await api!.list(
        mine: mine,
        search: search.text.trim(),
        category: category,
        sort: sort,
        cursor: more ? cursor : null,
      );
      if (mounted) {
        setState(() {
          policy = result.policy;
          final merged = more ? [...files, ...result.files] : result.files;
          files = policy.enabled
              ? {for (final f in merged) f.id: f}.values.toList()
              : [];
          cursor = policy.enabled ? result.nextCursor : null;
          if (!policy.categories.contains(category)) category = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = message(e);
          policy = const ResourcePolicy();
          files = [];
          cursor = null;
          if (e is DriveFailure && e.code == 'LOGIN_REQUIRED') tasks = [];
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void updateProgress(double value) {
    if (!mounted) return;
    final now = DateTime.now();
    if (value < 1 && now.difference(lastProgress).inMilliseconds < 150) return;
    lastProgress = now;
    setState(() => progress = value.clamp(0, 1));
  }

  Future<void> choose() async {
    if (busy || loading || api == null || !policy.canUpload) return;
    setState(() {
      busy = true;
      error = null;
      activity = tr('选择资料…', 'Choosing resource…');
      progress = 0;
    });
    DriveUpload? task;
    try {
      final chosen = await FilePicker.platform.pickFiles(withData: false);
      if (chosen == null || !mounted) return;
      final path = chosen.files.single.path;
      if (path == null) throw const DriveFailure('LOCAL_FILE_MISSING');
      final source = File(path);
      final size = await source.length();
      if (size > policy.maxFileBytes) {
        throw const DriveFailure('FILE_TOO_LARGE');
      }
      if (!mounted) return;
      final details = await showDialog<({String category, String description})>(
        context: context,
        builder: (_) => _ContributionDialog(
          tr: tr,
          name: chosen.files.single.name,
          categories: policy.categories,
          reviewRequired: policy.reviewRequired,
        ),
      );
      if (details == null || !mounted) return;
      setState(() => activity = tr('正在校验资料…', 'Checking resource…'));
      final checksum = (await sha256.bind(source.openRead()).first).toString();
      api!.guard();
      task = DriveUpload(
        id: const Uuid().v4(),
        path: path,
        name: chosen.files.single.name,
        size: size,
        checksum: checksum,
        category: details.category,
        description: details.description,
      );
      tasks = [...tasks.where((t) => t.state != 'done'), task];
      await queue!.save(tasks);
    } catch (e) {
      task = null;
      if (mounted) setState(() => error = message(e));
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          activity = null;
        });
      }
    }
    if (task != null && mounted) await upload(task);
  }

  Future<void> upload(DriveUpload task) async {
    if (busy || loading || !policy.canUpload || api == null) return;
    setState(() {
      busy = true;
      error = null;
      activity = tr('正在上传', 'Uploading');
      progress = 0;
      task.state = 'uploading';
    });
    try {
      await queue!.save(tasks);
      final file = await api!.upload(task, updateProgress);
      task.state = 'done';
      await queue!.save(tasks);
      if (mounted) {
        setState(
          () => activity = file.published
              ? tr('上传成功，已公开', 'Uploaded and published')
              : '${tr('上传完成', 'Upload complete')} · ${status(file.status)}',
        );
        await refresh();
      }
    } catch (e) {
      task.state = 'failed';
      try {
        await queue!.save(tasks);
      } catch (_) {
        /* keep the source untouched */
      }
      if (mounted) setState(() => error = message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> copyWebLink(PublicResource file) async {
    final client = api;
    if (client is! ResourceWebShareApi) return;
    try {
      final url = await (client as ResourceWebShareApi).webShare(file);
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('浏览器下载链接已复制，可发给未安装 App 的朋友')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message(e))));
      }
    }
  }

  Future<void> deleteFile(PublicResource file) async {
    if (busy || !file.canDelete || api is! ResourceDeletionApi) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这份公共资料？'),
        content: const Text('将移除你在公共网盘中的这份资料。其他群或用户仍在使用的文件会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    try {
      await (api as ResourceDeletionApi).deleteResource(file);
      if (mounted) await refresh();
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> download(PublicResource file) async {
    if (busy ||
        loading ||
        api == null ||
        !policy.canDownload ||
        !file.published) {
      return;
    }
    if (isApk(file.name)) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: SizedBox(
            width: 320,
            child: ApkFileCard(
              name: file.name,
              size: file.size,
              guard: api!.guard,
              createdAt: file.createdAt,
              cached: () async {
                api!.guard();
                final f = await ApkFiles.target(api!.owner, file.id, file.name);
                final valid = await ApkFiles.valid(f, file.size, file.checksum);
                api!.guard();
                return valid ? f.path : null;
              },
              load: (changed) async {
                final path = await api!.download(file, changed);
                api!.guard();
                return ApkFiles.stage(api!.owner, file.id, file.name, path);
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
      activity = tr('正在下载并校验', 'Downloading and verifying');
      progress = 0;
    });
    try {
      final path = await api!.download(file, updateProgress);
      api!.guard();
      if (!mounted) return;
      setState(() => activity = tr('下载完成，校验通过', 'Download verified'));
      final result = await OpenFilex.open(path);
      if (mounted && result.type != ResultType.done) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('文件已保存', 'File saved')),
            content: SelectableText(path),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('知道了', 'OK')),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String status(String value) => switch (value) {
    'published' => tr('已公开', 'Published'),
    'pending' => tr('待审核', 'Pending review'),
    'rejected' => tr('未通过审核', 'Not approved'),
    'hidden' => tr('已下架', 'Removed'),
    'uploading' => tr('上传未完成', 'Upload incomplete'),
    _ => tr('暂不可用', 'Unavailable'),
  };
  String bytes(int n) => n >= 1073741824
      ? '${(n / 1073741824).toStringAsFixed(1)} GB'
      : n >= 1048576
      ? '${(n / 1048576).toStringAsFixed(1)} MB'
      : n >= 1024
      ? '${(n / 1024).toStringAsFixed(1)} KB'
      : '$n B';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(tr('公共网盘', 'Public cloud drive')),
      actions: [
        IconButton(
          tooltip: tr('刷新', 'Refresh'),
          onPressed: busy || loading
              ? null
              : () async {
                  if (api == null) {
                    await connect();
                    if (mounted) setState(() {});
                  } else {
                    await refresh();
                  }
                },
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: tr('备份与存储设置', 'Backup and storage settings'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => widget.settingsPage),
          ),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    floatingActionButton: api == null || !policy.canUpload
        ? null
        : FloatingActionButton.extended(
            onPressed: busy || loading ? null : choose,
            icon: const Icon(Icons.upload_file),
            label: Text(tr('上传资料', 'Contribute')),
          ),
    body: RefreshIndicator(
      onRefresh: () => refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          if (api == null)
            Text(
              tr(
                '正在建立游客身份，请检查网络后重试。浏览和下载公开资料无需注册。',
                'Preparing the guest identity. Check the network and retry. Public browsing and downloads do not require registration.',
              ),
            )
          else ...[
            if (loading) const LinearProgressIndicator(),
            if (!policy.enabled && !loading && error == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  tr(
                    '公共资源正在准备中\n开放后可在这里浏览、上传和下载资料。',
                    'The shared library is being prepared.\nBrowse, contribute and download here once it opens.',
                  ),
                ),
              ),
            if (policy.enabled) ...[
              Wrap(
                spacing: 8,
                children: [
                  for (final value in [false, true])
                    ChoiceChip(
                      label: Text(
                        value
                            ? tr('我的投稿', 'My contributions')
                            : tr('全部资源', 'All resources'),
                      ),
                      selected: mine == value,
                      onSelected: busy || loading
                          ? null
                          : (_) {
                              setState(() {
                                mine = value;
                                files = [];
                                cursor = null;
                              });
                              refresh();
                            },
                    ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: search,
                      onSubmitted: busy || loading ? null : (_) => refresh(),
                      decoration: InputDecoration(
                        hintText: tr('搜索资料', 'Search resources'),
                        isDense: true,
                        suffixIcon: IconButton(
                          tooltip: tr('搜索', 'Search'),
                          onPressed: busy || loading ? null : () => refresh(),
                          icon: const Icon(Icons.search),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: sort,
                    onChanged: busy || loading
                        ? null
                        : (value) {
                            setState(() => sort = value!);
                            refresh();
                          },
                    items: [
                      for (final entry in {
                        'time': tr('最新', 'Newest'),
                        'popular': tr('热门', 'Popular'),
                        'name': tr('名称', 'Name'),
                        'size': tr('大小', 'Size'),
                      }.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                  ),
                ],
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final value in [
                      '',
                      'type:document',
                      'type:file',
                      'type:image',
                      'type:audio',
                      'type:video',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(
                            value.isEmpty
                                ? tr('全部', 'All')
                                : {
                                    'type:document': tr('文档', 'Documents'),
                                    'type:file': tr('文件', 'Files'),
                                    'type:image': tr('图片', 'Images'),
                                    'type:audio': tr('音频', 'Audio'),
                                    'type:video': tr('视频', 'Video'),
                                  }[value]!,
                          ),
                          selected: category == value,
                          onSelected: busy || loading
                              ? null
                              : (_) {
                                  setState(() => category = value);
                                  refresh();
                                },
                        ),
                      ),
                  ],
                ),
              ),
              if (files.isEmpty && !loading)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    mine
                        ? tr('还没有投稿', 'No contributions yet')
                        : tr('暂无符合条件的公开资料', 'No matching published resources'),
                  ),
                ),
              for (final file in files) ...[
                if (resourceIsImage(file.name) &&
                    file.published &&
                    policy.canDownload &&
                    api is ResourcePreviewApi)
                  ResourceImagePreview(
                    key: ValueKey('preview:${file.id}'),
                    api: api as ResourcePreviewApi,
                    file: file,
                    onDownload: () => download(file),
                    onShare: api is ResourceWebShareApi
                        ? () => copyWebLink(file)
                        : null,
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    isApk(file.name)
                        ? Icons.android
                        : Icons.description_outlined,
                  ),
                  title: Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: WindowsContentText(
                    child: Text(
                      [
                        if (isApk(file.name)) 'Android安装包',
                        bytes(file.size),
                        if (file.category.isNotEmpty) file.category,
                        if (file.author.isNotEmpty) file.author,
                        if (mine) status(file.status),
                        if (file.description.isNotEmpty) file.description,
                        if (mine && file.reviewNote.isNotEmpty) file.reviewNote,
                      ].join(' · '),
                      maxLines: mine ? 6 : 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onTap:
                      busy || loading || !policy.canDownload || !file.published
                      ? null
                      : () => download(file),
                  trailing:
                      (file.canDelete && api is ResourceDeletionApi) ||
                          (file.published &&
                              (widget.onShare != null ||
                                  widget.onSaveToGroup != null ||
                                  api is ResourceWebShareApi))
                      ? PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'delete') {
                              deleteFile(file);
                            } else if (v == 'web') {
                              copyWebLink(file);
                            } else if (v == 'share') {
                              widget.onShare!(file);
                            } else if (v == 'group') {
                              widget.onSaveToGroup!(file);
                            } else if (!busy &&
                                !loading &&
                                policy.canDownload) {
                              download(file);
                            }
                          },
                          itemBuilder: (_) => [
                            if (widget.onSaveToGroup != null &&
                                policy.groupTransferEnabled &&
                                file.published)
                              const PopupMenuItem(
                                value: 'group',
                                child: Text('转存到群文件'),
                              ),
                            if (file.canDelete && api is ResourceDeletionApi)
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('删除我的文件'),
                              ),
                            const PopupMenuItem(
                              value: 'download',
                              child: Text('下载并打开'),
                            ),
                            if (api is ResourceWebShareApi &&
                                policy.canDownload)
                              const PopupMenuItem(
                                value: 'web',
                                child: Text('复制浏览器下载链接'),
                              ),
                            if (widget.onShare != null)
                              const PopupMenuItem(
                                value: 'share',
                                child: Text('分享 / 收藏 / 引用'),
                              ),
                          ],
                        )
                      : file.published
                      ? IconButton(
                          tooltip: tr('下载并打开', 'Download and open'),
                          onPressed: busy || loading || !policy.canDownload
                              ? null
                              : () => download(file),
                          icon: const Icon(Icons.download_outlined),
                        )
                      : null,
                ),
              ],
              if (cursor != null)
                TextButton(
                  onPressed: busy || loading ? null : () => refresh(more: true),
                  child: Text(tr('加载更多', 'Load more')),
                ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (activity != null)
              Text('$activity${busy ? ' ${(progress * 100).floor()}%' : ''}'),
            if (busy)
              LinearProgressIndicator(value: progress > 0 ? progress : null),
            if (tasks.any((t) => t.state != 'done')) ...[
              const SizedBox(height: 12),
              Text(tr('未完成的上传', 'Incomplete uploads')),
              for (final task in tasks.where((t) => t.state != 'done'))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    task.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    task.state == 'uploading'
                        ? tr('上传中', 'Uploading')
                        : tr(
                            '未完成 · 本地文件保留',
                            'Incomplete · local file preserved',
                          ),
                  ),
                  trailing: TextButton(
                    onPressed: busy || loading || !policy.canUpload
                        ? null
                        : () => upload(task),
                    child: Text(tr('重试', 'Retry')),
                  ),
                ),
            ],
          ],
        ],
      ),
    ),
  );
}

class _ContributionDialog extends StatefulWidget {
  const _ContributionDialog({
    required this.tr,
    required this.name,
    required this.categories,
    required this.reviewRequired,
  });
  final String Function(String, String) tr;
  final String name;
  final List<String> categories;
  final bool reviewRequired;
  @override
  State<_ContributionDialog> createState() => _ContributionDialogState();
}

class _ContributionDialogState extends State<_ContributionDialog> {
  final description = TextEditingController();
  String category = '';
  @override
  void dispose() {
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.tr('上传公共资料', 'Contribute a resource')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.name),
          const SizedBox(height: 12),
          Text(
            widget.tr(
              '上传后成为公共资料，请勿上传私人内容。',
              'Uploaded files become public. Do not upload private content.',
            ),
          ),
          Text(
            widget.reviewRequired
                ? widget.tr('审核通过后公开。', 'Published after approval.')
                : widget.tr(
                    '当前上传完成后直接公开。',
                    'Published immediately after upload.',
                  ),
          ),
          if (widget.categories.isNotEmpty)
            DropdownButton<String>(
              isExpanded: true,
              value: category,
              items: [
                DropdownMenuItem(
                  value: '',
                  child: Text(widget.tr('未分类', 'Uncategorized')),
                ),
                for (final c in widget.categories)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: (v) => setState(() => category = v!),
            ),
          TextField(
            controller: description,
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: widget.tr('资料说明（选填）', 'Description (optional)'),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.tr('取消', 'Cancel')),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (
          category: category,
          description: description.text.trim(),
        )),
        child: Text(widget.tr('确认上传', 'Contribute')),
      ),
    ],
  );
}
