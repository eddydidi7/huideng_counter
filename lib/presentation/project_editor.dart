import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../core/app_controller.dart';
import '../domain/models.dart';
import 'shared.dart';

class ProjectEditor extends StatefulWidget {
  final AppController app;
  final CounterProject? project;
  const ProjectEditor({super.key, required this.app, this.project});
  @override
  State<ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends State<ProjectEditor> {
  late final name = TextEditingController(text: widget.project?.name);
  late String? imagePath = widget.project?.imagePath;
  bool saving = false;
  final form = GlobalKey<FormState>();
  AppController get app => widget.app;
  late final repository = app.repository;
  late final scope = app.scopeId;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
        allowMultiple: false,
      );
      if (result == null || result.files.single.path == null) return;
      if (result.files.single.size > 20 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                app.text('图片不能超过 20 MB', 'Image must be smaller than 20 MB'),
              ),
            ),
          );
        }
        return;
      }
      if (mounted) setState(() => imagePath = result.files.single.path);
    } catch (e) {
      if (mounted) showFailure(context, app, e);
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate() || saving) return;
    setState(() => saving = true);
    try {
      var savedImage = imagePath;
      if (imagePath != null && imagePath != widget.project?.imagePath) {
        final dir = Directory(
          p.joinAll([
            (await getApplicationSupportDirectory()).path,
            ...scope == 'guest' ? ['images'] : ['accounts', scope, 'images'],
          ]),
        );
        await dir.create(recursive: true);
        savedImage = (await File(imagePath!).copy(
          p.join(dir.path, '${const Uuid().v4()}${p.extension(imagePath!)}'),
        )).path;
      }
      await repository.saveProject(
        name.text,
        savedImage,
        id: widget.project?.id,
      );
      await app.reload();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => saving = false);
        showFailure(context, app, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.project == null
            ? app.text('新建项目', 'New project')
            : app.text('编辑项目', 'Edit project'),
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(child: ProjectImage(path: imagePath, size: 150)),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: saving ? null : pick,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(app.text('选择本地图片', 'Choose local image')),
              ),
              if (imagePath != null)
                TextButton(
                  onPressed: saving
                      ? null
                      : () => setState(() => imagePath = null),
                  child: Text(app.text('移除图片', 'Remove image')),
                ),
              const SizedBox(height: 24),
              TextFormField(
                controller: name,
                maxLength: 80,
                autofocus: widget.project == null,
                decoration: InputDecoration(
                  labelText: app.text('项目名称', 'Project name'),
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? app.text('请输入项目名称', 'Enter a project name')
                    : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: saving ? null : save,
                child: Text(app.text('保存项目', 'Save project')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
