import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'project.dart';
import 'project_name_dialog.dart';
import 'project_repository.dart';

const _unsortedValue = '__unsorted__';
const _newProjectValue = '__new__';

/// "Project: name ▾" chip for the composer — sets the save target for
/// generated takes. Mirrors the web frontend's `ProjectSelect`.
class ProjectSelect extends StatefulWidget {
  final ProjectRepository repository;

  /// Called on load and whenever the active project changes.
  final ValueChanged<String?>? onChanged;

  const ProjectSelect({super.key, required this.repository, this.onChanged});

  @override
  State<ProjectSelect> createState() => ProjectSelectState();
}

class ProjectSelectState extends State<ProjectSelect> {
  List<Project> _projects = [];
  String? _activeId;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  /// Reloads the project list and active id (e.g. after the Gallery tab
  /// creates, renames, or deletes a project).
  Future<void> refresh() async {
    final projects = await widget.repository.load();
    final storedId = await widget.repository.loadActiveId();
    // The active project may have been deleted from the Gallery tab.
    final valid = storedId != null && projects.any((p) => p.id == storedId);
    if (storedId != null && !valid) {
      await widget.repository.setActiveId(null);
    }
    final activeId = valid ? storedId : null;
    if (mounted) {
      setState(() {
        _projects = projects;
        _activeId = activeId;
      });
    }
    widget.onChanged?.call(activeId);
  }

  Future<void> _select(String? id) async {
    await widget.repository.setActiveId(id);
    setState(() => _activeId = id);
    widget.onChanged?.call(id);
  }

  Future<void> _createProject() async {
    final name = await showProjectNameDialog(context, title: 'New project');
    if (name == null || name.trim().isEmpty) return;
    final project = await widget.repository.add(name);
    setState(() => _projects = [..._projects, project]);
    await _select(project.id);
  }

  String get _activeName {
    for (final p in _projects) {
      if (p.id == _activeId) return p.name;
    }
    return 'Unsorted';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.brand;
    return PopupMenuButton<String>(
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value == _newProjectValue) {
          _createProject();
        } else if (value == _unsortedValue) {
          _select(null);
        } else {
          _select(value);
        }
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem(value: _unsortedValue, child: Text('Unsorted')),
        for (final p in _projects) PopupMenuItem(value: p.id, child: Text(p.name)),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _newProjectValue,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.add_rounded, size: 17),
              SizedBox(width: 8),
              Text('New project'),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_outlined, size: 15, color: c.text2),
            const SizedBox(width: 7),
            Text(
              _activeName,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: c.text,
              ),
            ),
            Icon(Icons.expand_more_rounded, size: 16, color: c.text3),
          ],
        ),
      ),
    );
  }
}
