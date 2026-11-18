import 'dart:io';

import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart'
    show PoseHubActionLibrary;

/// Resolves a Flutter package asset to its sibling checkout for test file I/O.
File bundledPoseHubFile(String relativePath) => File(
  PoseHubActionLibrary.assetRoot.replaceFirst('packages/', '../') +
      relativePath,
);
