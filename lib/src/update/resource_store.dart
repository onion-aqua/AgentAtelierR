import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'resource_integrity.dart';
import 'resource_manifest.dart';
import 'resource_models.dart';
import 'update_manifest.dart';

typedef ResourceRootDirectoryProvider = Future<Directory> Function();

final class ResourceSnapshotStore {
  ResourceSnapshotStore({ResourceRootDirectoryProvider? rootDirectory})
    : _rootDirectory = rootDirectory ?? _defaultRootDirectory;

  final ResourceRootDirectoryProvider _rootDirectory;
  final ResourceSnapshotManifestParser _parser =
      const ResourceSnapshotManifestParser();
  final Random _random = Random.secure();
  ResourceActivationPointer? _pointer;
  Future<void>? _initializing;

  ResourceActivationPointer? get pointer => _pointer;
  ResourceSnapshotReference? get activeReference => _pointer?.active;
  ResourceSnapshotReference? get previousReference => _pointer?.previous;
  int get highestCommittedReleaseSeq {
    final active = _pointer?.active?.releaseSeq ?? 0;
    final previous = _pointer?.previous?.releaseSeq ?? 0;
    return active > previous ? active : previous;
  }

  Future<void> initialize() => _initializing ??= _initialize();

  Future<ResourceSnapshotManifest?> activeManifest() async {
    await initialize();
    final reference = activeReference;
    return reference == null ? null : loadSnapshot(reference);
  }

  Future<ResourceSnapshotManifest> loadSnapshot(
    ResourceSnapshotReference reference,
  ) async {
    _validateReference(reference);
    final file = await _snapshotFile(reference.manifestSha256);
    if (!await file.exists()) {
      throw const ResourceUpdateException(
        'resource_snapshot_missing',
        '资源快照清单已丢失',
      );
    }
    final bytes = await file.readAsBytes();
    if (await resourceSha256Bytes(bytes) != reference.manifestSha256) {
      throw const ResourceUpdateException(
        'resource_snapshot_corrupt',
        '本地资源快照清单校验失败',
      );
    }
    final manifest = _parser.parseCanonical(bytes);
    if (manifest.snapshotId != reference.snapshotId) {
      throw const ResourceUpdateException(
        'resource_snapshot_identity_mismatch',
        '本地资源快照身份不匹配',
      );
    }
    return manifest;
  }

  Future<File> createStagingFile(String sha256) async {
    _requireSha256(sha256);
    final directory = await _stagingDirectory();
    await directory.create(recursive: true);
    return File(
      _join(
        directory.path,
        '$sha256.${DateTime.now().microsecondsSinceEpoch}.${_random.nextInt(1 << 32)}.download',
      ),
    );
  }

  Future<bool> hasVerifiedObject(ResourceObject object) async {
    final file = await objectFile(object.sha256);
    final valid = await resourceFileMatches(
      file,
      size: object.size,
      sha256: object.sha256,
    );
    if (!valid && await file.exists()) await file.delete();
    return valid;
  }

  Future<File> commitObject(File staged, ResourceObject object) async {
    final staging = await _stagingDirectory();
    if (!_isDirectChild(staging, staged)) {
      throw const ResourceUpdateException(
        'invalid_staging_path',
        '资源暂存文件不在受管理目录内',
      );
    }
    if (!await resourceFileMatches(
      staged,
      size: object.size,
      sha256: object.sha256,
    )) {
      if (await staged.exists()) await staged.delete();
      throw const ResourceUpdateException(
        'resource_object_verification_failed',
        '资源对象校验失败',
      );
    }
    final target = await objectFile(object.sha256);
    await target.parent.create(recursive: true);
    if (await resourceFileMatches(
      target,
      size: object.size,
      sha256: object.sha256,
    )) {
      await staged.delete();
      return target;
    }
    if (await target.exists()) await target.delete();
    await staged.rename(target.path);
    return target;
  }

  Future<File> objectFile(String sha256) async {
    _requireSha256(sha256);
    final root = await _root();
    return File(
      _joinAll([root.path, 'objects', sha256.substring(0, 2), sha256]),
    );
  }

  Future<ResourceSnapshotReference> stageSnapshot({
    required ResourceSnapshotManifest manifest,
    required Uint8List authenticatedBytes,
    required String manifestSha256,
    required int releaseSeq,
  }) async {
    await initialize();
    _requireSha256(manifestSha256);
    if (await resourceSha256Bytes(authenticatedBytes) != manifestSha256) {
      throw const ResourceUpdateException(
        'resource_snapshot_hash_mismatch',
        '暂存资源快照清单校验失败',
      );
    }
    final reparsed = _parser.parseCanonical(authenticatedBytes);
    if (reparsed.snapshotId != manifest.snapshotId ||
        reparsed.objects.length != manifest.objects.length) {
      throw const ResourceUpdateException(
        'resource_snapshot_changed',
        '暂存资源快照清单与已验证内容不一致',
      );
    }
    await verifySnapshotObjects(manifest);
    if (releaseSeq <= 0) {
      throw const ResourceUpdateException(
        'invalid_resource_release_seq',
        '资源发布序号无效',
      );
    }
    final reference = ResourceSnapshotReference(
      releaseSeq: releaseSeq,
      snapshotId: manifest.snapshotId,
      manifestSha256: manifestSha256,
    );
    final floor = highestCommittedReleaseSeq;
    if (releaseSeq < floor) {
      throw const ResourceUpdateException(
        'resource_release_rollback',
        '不能暂存早于已激活历史的资源发布',
      );
    }
    for (final pending in await pendingSnapshots()) {
      if (pending.releaseSeq == releaseSeq && pending != reference) {
        throw const ResourceUpdateException(
          'resource_release_identity_conflict',
          '相同资源发布序号对应了不同快照',
        );
      }
    }
    final file = await _snapshotFile(manifestSha256);
    await _writeImmutable(file, authenticatedBytes);
    final pending = await _pendingFile(reference);
    await _writeCanonicalAtomic(pending, {
      ...reference.toJson(),
      'staged_at_us': DateTime.now().microsecondsSinceEpoch,
    });
    return reference;
  }

  Future<void> verifySnapshotObjects(ResourceSnapshotManifest manifest) async {
    for (final object in manifest.objects) {
      if (!await hasVerifiedObject(object)) {
        throw ResourceUpdateException(
          'resource_object_missing',
          '资源快照缺少已校验对象：${object.path}',
        );
      }
    }
  }

  Future<ResourceActivationPointer> activate(
    ResourceSnapshotReference reference,
  ) async {
    await initialize();
    final manifest = await loadSnapshot(reference);
    await verifySnapshotObjects(manifest);
    final current = _pointer;
    if (current?.active == reference) {
      await prunePendingThrough(reference);
      return current!;
    }
    final floor = highestCommittedReleaseSeq;
    if (reference.releaseSeq < floor) {
      throw const ResourceUpdateException(
        'resource_release_rollback',
        '不能激活早于已激活历史的资源发布',
      );
    }
    if (reference.releaseSeq == floor &&
        reference != current?.active &&
        reference != current?.previous) {
      throw const ResourceUpdateException(
        'resource_release_identity_conflict',
        '相同资源发布序号对应了不同快照',
      );
    }
    final pointer = ResourceActivationPointer(
      generation: (current?.generation ?? 0) + 1,
      active: reference,
      previous: current?.active,
      action: 'activate',
    );
    await _commitPointer(pointer);
    await prunePendingThrough(reference);
    return pointer;
  }

  Future<ResourceActivationPointer> rollback() async {
    await initialize();
    final current = _pointer;
    final previous = current?.previous;
    if (current == null || previous == null) {
      throw const ResourceUpdateException(
        'resource_rollback_unavailable',
        '没有可回退的上一资源快照',
      );
    }
    final manifest = await loadSnapshot(previous);
    await verifySnapshotObjects(manifest);
    final pointer = ResourceActivationPointer(
      generation: current.generation + 1,
      active: previous,
      previous: current.active,
      action: 'rollback',
    );
    await _commitPointer(pointer);
    return pointer;
  }

  Future<ResourceActivationPointer> deactivateForRecovery() async {
    await initialize();
    final current = _pointer;
    final pointer = ResourceActivationPointer(
      generation: (current?.generation ?? 0) + 1,
      active: null,
      previous: current?.active,
      action: 'recovery',
    );
    await _commitPointer(pointer);
    return pointer;
  }

  Future<List<ResourceSnapshotReference>> pendingSnapshots() async {
    await initialize();
    final directory = await _pendingDirectory();
    if (!await directory.exists()) return const [];
    final values = <({int stagedAtUs, ResourceSnapshotReference reference})>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        final pending = _parsePending(decoded);
        await loadSnapshot(pending.reference);
        values.add(pending);
      } on Object {
        // Invalid metadata never becomes active and is left for explicit cache
        // cleanup inside this managed directory.
      }
    }
    values.sort((left, right) {
      final sequence = right.reference.releaseSeq.compareTo(
        left.reference.releaseSeq,
      );
      return sequence != 0
          ? sequence
          : right.stagedAtUs.compareTo(left.stagedAtUs);
    });
    return List.unmodifiable(values.map((value) => value.reference));
  }

  Future<Uint8List?> readActiveAsset(String path) async {
    final file = await resolveActiveFile(path);
    return file?.readAsBytes();
  }

  Future<File?> resolveActiveFile(String path) async {
    requireSafeResourcePath(path);
    final manifest = await activeManifest();
    final object = manifest?.objectsByPath[path];
    if (object == null) return null;
    final file = await objectFile(object.sha256);
    if (!await resourceFileMatches(
      file,
      size: object.size,
      sha256: object.sha256,
    )) {
      throw ResourceUpdateException(
        'active_resource_corrupt',
        '已激活资源校验失败：$path',
      );
    }
    return file;
  }

  Future<void> clearUnreferencedCache() async {
    await initialize();
    final references = <ResourceSnapshotReference>{};
    final active = _pointer?.active;
    final previous = _pointer?.previous;
    if (active != null) references.add(active);
    if (previous != null) references.add(previous);
    references.addAll(await pendingSnapshots());
    final retainedObjects = <String>{};
    final retainedManifests = <String>{};
    for (final reference in references) {
      retainedManifests.add(reference.manifestSha256);
      try {
        final manifest = await loadSnapshot(reference);
        retainedObjects.addAll(manifest.objects.map((object) => object.sha256));
      } on Object {
        // Keep the referenced manifest for recovery diagnostics. Corrupt or
        // missing object files are not retained merely by their filename.
      }
    }
    final root = await _root();
    await _deleteManagedFiles(
      Directory(_join(root.path, 'objects')),
      keep: retainedObjects,
      namePattern: RegExp(r'^[0-9a-f]{64}$'),
      recursive: true,
    );
    await _deleteManagedFiles(
      Directory(_join(root.path, 'snapshots')),
      keep: retainedManifests.map((hash) => '$hash.json').toSet(),
      namePattern: RegExp(r'^[0-9a-f]{64}\.json$'),
    );
    await _deleteManagedFiles(
      Directory(_join(root.path, 'staging')),
      keep: const {},
      namePattern: RegExp(
        r'^[0-9a-f]{64}\.[0-9]+\.[0-9]+\.download(?:\.part)?$',
      ),
    );
  }

  Future<void> _initialize() async {
    final directory = await _pointerDirectory();
    if (!await directory.exists()) {
      _pointer = null;
      return;
    }
    final candidates = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          RegExp(r'[\\/]\d{20}\.json$').hasMatch(entity.path)) {
        candidates.add(entity);
      }
    }
    candidates.sort((left, right) => right.path.compareTo(left.path));
    for (final file in candidates) {
      try {
        final source = await file.readAsString();
        final decoded = jsonDecode(source);
        if (canonicalJsonEncode(decoded) != source) continue;
        final pointer = _parsePointer(decoded);
        final filename = file.uri.pathSegments.last;
        if (filename !=
            '${pointer.generation.toString().padLeft(20, '0')}.json') {
          continue;
        }
        _pointer = pointer;
        return;
      } on Object {
        // The previous immutable generation remains a valid atomic fallback.
      }
    }
    _pointer = null;
  }

  Future<void> _commitPointer(ResourceActivationPointer pointer) async {
    final directory = await _pointerDirectory();
    await directory.create(recursive: true);
    final file = File(
      _join(
        directory.path,
        '${pointer.generation.toString().padLeft(20, '0')}.json',
      ),
    );
    await _writeCanonicalAtomic(file, {
      'action': pointer.action,
      'active': pointer.active?.toJson(),
      'generation': pointer.generation,
      'previous': pointer.previous?.toJson(),
      'schema_version': 1,
    });
    _pointer = pointer;
  }

  ResourceActivationPointer _parsePointer(Object? value) {
    final json = _strictObject(value, const {
      'action',
      'active',
      'generation',
      'previous',
      'schema_version',
    });
    if (json['schema_version'] != 1 ||
        json['generation'] is! int ||
        (json['generation'] as int) <= 0 ||
        !const {'activate', 'rollback', 'recovery'}.contains(json['action'])) {
      throw const FormatException('Invalid resource activation pointer');
    }
    final active = json['active'] == null
        ? null
        : _parseReference(json['active']);
    final previous = json['previous'] == null
        ? null
        : _parseReference(json['previous']);
    if (active != null && active == previous) {
      throw const FormatException('Active and previous snapshots must differ');
    }
    return ResourceActivationPointer(
      generation: json['generation'] as int,
      active: active,
      previous: previous,
      action: json['action'] as String,
    );
  }

  ResourceSnapshotReference _parseReference(Object? value) {
    final json = _strictObject(value, const {
      'manifest_sha256',
      'release_seq',
      'snapshot_id',
    });
    final releaseSeq = json['release_seq'];
    final snapshotId = json['snapshot_id'];
    final hash = json['manifest_sha256'];
    if (releaseSeq is! int ||
        releaseSeq <= 0 ||
        snapshotId is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(snapshotId) ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid resource snapshot reference');
    }
    return ResourceSnapshotReference(
      releaseSeq: releaseSeq,
      snapshotId: snapshotId,
      manifestSha256: hash,
    );
  }

  ({int stagedAtUs, ResourceSnapshotReference reference}) _parsePending(
    Object? value,
  ) {
    final json = _strictObject(value, const {
      'manifest_sha256',
      'release_seq',
      'snapshot_id',
      'staged_at_us',
    });
    final stagedAtUs = json.remove('staged_at_us');
    if (stagedAtUs is! int || stagedAtUs <= 0) {
      throw const FormatException('Invalid resource pending timestamp');
    }
    return (stagedAtUs: stagedAtUs, reference: _parseReference(json));
  }

  Future<File> _snapshotFile(String sha256) async {
    _requireSha256(sha256);
    final root = await _root();
    return File(_joinAll([root.path, 'snapshots', '$sha256.json']));
  }

  Future<File> _pendingFile(ResourceSnapshotReference reference) async {
    final directory = await _pendingDirectory();
    return File(_join(directory.path, '${reference.manifestSha256}.json'));
  }

  Future<void> _deletePending(ResourceSnapshotReference reference) async {
    final file = await _pendingFile(reference);
    if (await file.exists()) await file.delete();
  }

  Future<void> discardPending(ResourceSnapshotReference reference) =>
      _deletePending(reference);

  Future<void> prunePendingThrough(ResourceSnapshotReference activated) async {
    final directory = await _pendingDirectory();
    if (!await directory.exists()) return;
    final current = await _pendingFile(activated);
    final older = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final pending = _parsePending(jsonDecode(await entity.readAsString()));
        if (pending.reference.releaseSeq <= activated.releaseSeq &&
            entity.absolute.path.toLowerCase() !=
                current.absolute.path.toLowerCase()) {
          older.add(entity);
        }
      } on Object {
        // Malformed metadata is not executed and remains eligible for the
        // bounded managed-cache cleanup.
      }
    }
    for (final file in older) {
      if (await file.exists()) await file.delete();
    }
    // Delete the activated marker last. If the process stops during pruning,
    // the next startup can identify the same cutoff and finish safely.
    await _deletePending(activated);
  }

  Future<Directory> _root() async {
    final root = await _rootDirectory();
    await root.create(recursive: true);
    return root;
  }

  Future<Directory> _stagingDirectory() async =>
      Directory(_join((await _root()).path, 'staging'));

  Future<Directory> _pointerDirectory() async =>
      Directory(_joinAll([(await _root()).path, 'state', 'pointers']));

  Future<Directory> _pendingDirectory() async =>
      Directory(_joinAll([(await _root()).path, 'state', 'pending']));

  Future<void> _writeImmutable(File file, Uint8List bytes) async {
    if (await file.exists()) {
      if (await resourceSha256Bytes(await file.readAsBytes()) ==
          await resourceSha256Bytes(bytes)) {
        return;
      }
      throw const ResourceUpdateException(
        'immutable_snapshot_conflict',
        '本地存在同名但内容不同的资源快照',
      );
    }
    await _writeAtomic(file, bytes);
  }

  Future<void> _writeCanonicalAtomic(File file, Object value) => _writeAtomic(
    file,
    Uint8List.fromList(utf8.encode(canonicalJsonEncode(value))),
  );

  Future<void> _writeAtomic(File file, Uint8List bytes) async {
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.${_random.nextInt(1 << 32)}.tmp',
    );
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _deleteManagedFiles(
    Directory directory, {
    required Set<String> keep,
    required RegExp namePattern,
    bool recursive = false,
  }) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(
      recursive: recursive,
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file) continue;
      final name = entity.uri.pathSegments.last;
      if (namePattern.hasMatch(name) && !keep.contains(name)) {
        await File(entity.path).delete();
      }
    }
  }

  static Map<String, dynamic> _strictObject(
    Object? value,
    Set<String> expected,
  ) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('Expected JSON object');
    }
    final json = Map<String, dynamic>.from(value);
    if (json.length != expected.length ||
        !json.keys.toSet().containsAll(expected)) {
      throw const FormatException('Unexpected JSON fields');
    }
    return json;
  }

  static void _validateReference(ResourceSnapshotReference reference) {
    if (reference.releaseSeq <= 0 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
            .hasMatch(reference.snapshotId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(reference.manifestSha256)) {
      throw const ResourceUpdateException(
        'invalid_snapshot_reference',
        '资源快照引用无效',
      );
    }
  }

  static void _requireSha256(String value) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const ResourceUpdateException(
        'invalid_resource_hash',
        '资源 SHA-256 格式无效',
      );
    }
  }

  static bool _isDirectChild(Directory directory, File file) {
    final parent = file.parent.absolute.path.toLowerCase();
    return parent == directory.absolute.path.toLowerCase();
  }

  static Future<Directory> _defaultRootDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(_join(support.path, 'agent_atelier_resource_updates_v1'));
  }

  static String _join(String left, String right) =>
      '$left${Platform.pathSeparator}$right';

  static String _joinAll(List<String> parts) =>
      parts.join(Platform.pathSeparator);
}
