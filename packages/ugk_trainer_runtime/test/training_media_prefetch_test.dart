import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

class _Downloads
    implements CatalogMediaRepository, CatalogMediaPriorityRepository {
  _Downloads(this.catalog);
  @override
  final PoseHubAppTestCatalog catalog;
  final calls = <(String, CatalogMediaPriority)>[];
  final jobs = <String, Completer<Uri>>{};

  @override
  Future<Uri> ensureFile(PoseHubPackFile file) =>
      ensureFileWithPriority(file, priority: CatalogMediaPriority.current);

  @override
  Future<Uri> ensureFileWithPriority(
    PoseHubPackFile file, {
    required CatalogMediaPriority priority,
  }) {
    calls.add((file.path, priority));
    return jobs.putIfAbsent(file.path, Completer<Uri>.new).future;
  }

  void ready(PoseHubPackAction action) =>
      jobs[action.video.path]!.complete(Uri.file('/verified/${action.id}.mp4'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File(
      '../ugk_trainer/assets/pose_hub/app-pack-r2-v10/catalog.json',
    ).readAsBytesSync(),
  );
  final actions = catalog.semanticCompleteActions.take(3).toList();

  test(
    'only the next video starts after the current video is verified',
    () async {
      final repository = _Downloads(catalog);
      final policy = TrainingMediaPolicy(repository: repository);
      final prepared = policy.prefetchActions(
        actions.map((action) => action.id),
      );
      expect(repository.calls, [
        (actions[0].video.path, CatalogMediaPriority.current),
      ]);
      repository.ready(actions[0]);
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, [
        (actions[0].video.path, CatalogMediaPriority.current),
        (actions[1].video.path, CatalogMediaPriority.prefetch),
      ]);
      repository.ready(actions[1]);
      await prepared;
      expect(repository.calls, hasLength(2));
    },
  );

  test(
    'jumping away drops lookahead while preserving the running video',
    () async {
      final repository = _Downloads(catalog);
      final policy = TrainingMediaPolicy(repository: repository);
      var current = true;
      final prepared = policy.prefetchActions(
        actions.map((action) => action.id),
        isCurrent: () => current,
      );
      current = false;
      repository.ready(actions[0]);
      await prepared;
      expect(repository.calls, [
        (actions[0].video.path, CatalogMediaPriority.current),
      ]);
    },
  );
}
