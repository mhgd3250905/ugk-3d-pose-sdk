import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_chat/ugk_coach_chat.dart';

import 'chat_controller_test.dart' show ChatHarness, chatCatalog, chatPlan;

TrainingLibraryConfig libraryConfig() => TrainingLibraryConfig(
  scopeManifest: coach.CoachActionScopeManifest.fromCatalogBytes(
    appId: 'chat-test',
    catalogBytes: utf8.encode(jsonEncode(chatCatalog().toJson())),
    allowedActionIds: const ['one', 'two', 'three'],
  ),
);

void main() {
  test('null library retains the existing Coach action scope', () async {
    final h = ChatHarness();
    addTearDown(h.close);
    expect(h.controller.profile.library, isNull);
    expect((await h.controller.start()).ok, isTrue);
    expect(h.controller.agent.actionScope!.plannableIds, {
      'one',
      'two',
      'three',
      'four',
    });
  });

  test(
    'library manifest is the canonical Coach tool catalogue scope',
    () async {
      final library = libraryConfig();
      final h = ChatHarness(library: library);
      addTearDown(h.close);
      expect((await h.controller.start()).ok, isTrue);
      expect(h.controller.profile.scopeManifest, same(library.scopeManifest));
      expect(
        h.controller.agent.actionScope!.manifest,
        same(library.scopeManifest),
      );
      expect(
        h.controller.catalog.drills.map((drill) => drill.id).toSet(),
        library.scopeManifest.allowedActionIds,
      );
    },
  );

  test('plan admission follows the library whitelist', () async {
    final h = ChatHarness(library: libraryConfig());
    addTearDown(h.close);
    expect((await h.controller.start()).ok, isTrue);
    final allowed = chatPlan();
    final excluded = chatPlan(third: 'four');
    expect(
      h.controller.agent.prepareTraining(
        allowed,
        context: requestForPlan(allowed),
      ),
      isNotNull,
    );
    expect(
      h.controller.agent.prepareTraining(
        excluded,
        context: requestForPlan(excluded),
      ),
      isNull,
    );
  });
}
