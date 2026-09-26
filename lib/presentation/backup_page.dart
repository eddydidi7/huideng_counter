import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/app_controller.dart';
import '../data/repositories/backup_repository.dart';
import '../data/repositories/sqlite_counter_repository.dart';

class BackupPage extends StatefulWidget {
  final AppController app;
  const BackupPage({super.key, required this.app});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool busy = false, restoreSettings = false;
  String? message;
  String? csvProject;
  DateTimeRange? csvRange;
  AppController get app => widget.app;

  Future<void> execute(bool importing, {bool csv = false}) async {
    if (busy || app.cloud?.busy == true) return;
    final current = app.repository;
    final scope = app.scopeId;
    if (current is! SqliteCounterRepository) return;
    final cloud = app.cloud;
    setState(() {
      busy = true;
      message = null;
    });
    if (cloud != null) {
      cloud.busy = true;
      cloud.changed();
      cloud.worker?.stop();
    }
    try {
      await cloud?.worker?.waitUntilIdle();
      final support = await getApplicationSupportDirectory();
      final root = Directory(
        p.joinAll([
          support.path,
          if (scope != 'guest') ...['accounts', scope],
          'backups',
        ]),
      );
      final backup = BackupRepository(current.db, root);
      if (importing) {
        final selected = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
        );
        if (selected == null) return;
        final path = selected.files.single.path;
        if (path == null) throw BackupFailure('file');
        final file = File(path);
        if (await file.length() > BackupRepository.maxBytes) {
          throw BackupFailure('size');
        }
        final bytes = await file.readAsBytes();
        if (!mounted) return;
        final confirmed =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(app.text('合并备份数据？', 'Merge backup data?')),
                content: Text(
                  app.text(
                    '新记录按 UUID 合并，重复计数不会重复增加。已有项目的名称、图片和顺序保留。导入前自动保存当前数据的恢复备份。',
                    'New records are merged by UUID without double counting. Existing project names, images and order are retained. A safety backup is saved before importing.',
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(app.text('取消', 'Cancel')),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(app.text('导入', 'Import')),
                  ),
                ],
              ),
            ) ??
            false;
        if (!confirmed || !mounted || !identical(app.repository, current)) {
          return;
        }
        await root.create(recursive: true);
        await File(
          p.join(
            root.path,
            'before-import-${DateTime.now().microsecondsSinceEpoch}.huideng',
          ),
        ).writeAsBytes(await backup.export(), flush: true);
        final added = await backup.import(
          bytes,
          restoreSettings: restoreSettings,
        );
        await app.reload();
        if (mounted) {
          setState(
            () => message = app.text(
              '导入完成，新增 $added 条计数变化。已有记录保留。',
              'Imported $added new count changes. Existing records retained.',
            ),
          );
        }
      } else {
        final bytes = csv
            ? await backup.exportCsv(
                projectId: csvProject,
                from: csvRange?.start,
                until: csvRange == null
                    ? null
                    : DateTime(
                        csvRange!.end.year,
                        csvRange!.end.month,
                        csvRange!.end.day + 1,
                      ),
              )
            : await backup.export();
        final date = DateTime.now().toIso8601String().replaceAll(':', '-');
        final path = await FilePicker.platform.saveFile(
          dialogTitle: app.text('保存数据备份', 'Save backup'),
          fileName: 'huideng-$date.${csv ? 'csv' : 'json'}',
          bytes: bytes,
        );
        if (path == null) return;
        // The installed file_picker version writes supplied bytes on all targets.
        if (mounted) {
          setState(
            () => message = app.text('备份已保存：\n$path', 'Backup saved:\n$path'),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => message = switch (e is BackupFailure ? e.code : '') {
            'owner' => app.text(
              '账号不匹配。账号备份请登录同一账号导入；访客备份请退出登录后导入。',
              'Account mismatch. Sign in to the same account for account backups; sign out for guest backups.',
            ),
            'missing_image' => app.text(
              '有项目图片尚未下载或文件已缺失。请先恢复图片后再导出或导入。',
              'A project image is missing or not downloaded. Restore the image before backing up or importing.',
            ),
            'size' => app.text(
              '备份上限为 100 MB，单张图片上限 20 MB。',
              'Backup limit is 100 MB; each image must be at most 20 MB.',
            ),
            'event_conflict' => app.text(
              '发现相同 UUID 但内容不同的记录，已取消整次导入，原数据保留。',
              'Conflicting records share a UUID. Import cancelled; existing data retained.',
            ),
            _ => app.text(
              '操作未完成。请检查备份文件、存储空间和文件权限；原记录保留。',
              'Could not complete. Check the backup file, storage space and permissions. Existing records retained.',
            ),
          },
        );
      }
    } finally {
      if (cloud != null) {
        cloud.busy = false;
        if (cloud.userId != null &&
            cloud.client?.auth.currentUser?.id == cloud.userId) {
          cloud.worker?.start();
        }
        cloud.changed();
      }
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(app.text('本地备份与恢复', 'Local backup and restore')),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                app.text(
                  '导出当前账号（或访客）的项目、图片、排序、设置和完整计数历史。不包含登录密码。备份文件未加密，请保存在自己的安全位置。',
                  'Export projects, images, order, settings and complete count history for this account or guest. Passwords are excluded. Backup files are unencrypted; keep them in a private location.',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: csvProject ?? '',
                decoration: InputDecoration(
                  labelText: app.text('CSV 导出项目', 'CSV projects'),
                ),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(app.text('全部项目', 'All projects')),
                  ),
                  for (final project in app.projects)
                    DropdownMenuItem(
                      value: project.id,
                      child: Text(project.name),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(
                        () => csvProject = value == '' ? null : value,
                      ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      csvRange == null
                          ? app.text('全部日期', 'All dates')
                          : '${csvRange!.start.toString().split(' ').first} — ${csvRange!.end.toString().split(' ').first}',
                    ),
                    onPressed: busy
                        ? null
                        : () async {
                            final range = await showDateRangePicker(
                              context: context,
                              firstDate: DateTime(1900),
                              lastDate: DateTime(2100),
                              initialDateRange: csvRange,
                            );
                            if (range != null && mounted) {
                              setState(() => csvRange = range);
                            }
                          },
                  ),
                  if (csvRange != null)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => csvRange = null),
                      child: Text(app.text('清除日期限制', 'Clear dates')),
                    ),
                ],
              ),
              FilledButton.icon(
                onPressed: busy ? null : () => execute(false, csv: true),
                icon: const Icon(Icons.save_alt),
                label: Text(
                  app.text('导出 CSV（Excel / WPS）', 'Export CSV (Excel / WPS)'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                app.text(
                  'CSV 用于查看项目和逐次计数历史，不含图片、设置，不能直接恢复。恢复全部数据请使用完整备份；仍支持旧备份文件导入。',
                  'CSV contains projects and individual count changes for spreadsheets. Images and settings are excluded; CSV cannot be restored. Use a full backup for recovery. Existing backup files remain supported.',
                ),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => execute(false),
                icon: const Icon(Icons.archive_outlined),
                label: Text(
                  app.text(
                    '保存 JSON 完整备份（含图片，可恢复）',
                    'Save full JSON backup (images and recovery)',
                  ),
                ),
              ),
              CheckboxListTile(
                value: restoreSettings,
                onChanged: busy
                    ? null
                    : (v) => setState(() => restoreSettings = v!),
                title: Text(
                  app.text('导入时恢复语言等设置', 'Restore settings when importing'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => execute(true),
                icon: const Icon(Icons.upload_file),
                label: Text(app.text('选择文件并导入', 'Choose backup to import')),
              ),
              if (busy) const LinearProgressIndicator(),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: SelectableText(message!),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
