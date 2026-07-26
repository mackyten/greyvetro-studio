/// A project groups gallery clips for one video — the foundation the
/// Storyboard and Timeline Editor phases attach to. Mirrors the web
/// frontend's `Project` type.
class Project {
  final String id;
  final String name;
  final DateTime createdAt;

  const Project({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  Project copyWith({String? name}) => Project(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Project',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );
}
