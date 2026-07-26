import 'package:flutter/material.dart';

/// Prompts for a project name (create or rename). Mirrors the web frontend's
/// `ProjectNameModal`.
Future<String?> showProjectNameDialog(
  BuildContext context, {
  required String title,
  String? initialName,
}) {
  final controller = TextEditingController(text: initialName ?? '');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Project name',
          hintText: 'e.g. ZIFRIEND',
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(title),
        ),
      ],
    ),
  );
}
