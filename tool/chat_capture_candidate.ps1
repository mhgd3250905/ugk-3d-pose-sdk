param(
  [string]$SourceRepository = 'E:/AII-3D/3D-Sport-AI/Sport-Helper-coach-ui-kit',
  [string]$BaselineDirectory = 'build/chat-extract-baseline/sf-3eb2a9e-v7',
  [string]$OutputDirectory = 'build/chat-extract-baseline/candidate-new',
  [string]$Frames = ''
)

$ErrorActionPreference = 'Stop'
$sdkRoot = Split-Path -Parent $PSScriptRoot
$baselineRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot $BaselineDirectory))
$candidateRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot $OutputDirectory))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot 'build')) + [IO.Path]::DirectorySeparatorChar
if (-not $baselineRoot.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not $candidateRoot.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Baseline and candidate output must stay inside SDK build.'
}
if (-not (Test-Path -LiteralPath (Join-Path $baselineRoot 'environment.json'))) {
  throw 'The original SF baseline environment is required.'
}
$baselineEnvironment = Get-Content -Raw -LiteralPath (Join-Path $baselineRoot 'environment.json') | ConvertFrom-Json -AsHashtable
$flutterCommand = [string]$baselineEnvironment.flutterCommand
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'chat_capture_sf_baseline.ps1') -SourceRepository $SourceRepository -OutputDirectory $OutputDirectory -FlutterCommand $flutterCommand -PrepareOnly
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$snapshotRoot = Join-Path $candidateRoot 'sf-source'
$configPath = Join-Path $snapshotRoot '.dart_tool/package_config.json'
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json -AsHashtable
$sdkPackages = @{
  ugk_coach = $sdkRoot
  ugk_coach_ui = Join-Path $sdkRoot 'packages/ugk_coach_ui'
  ugk_trainer = Join-Path $sdkRoot 'packages/ugk_trainer'
  ugk_trainer_runtime = Join-Path $sdkRoot 'packages/ugk_trainer_runtime'
  ugk_coach_chat = Join-Path $sdkRoot 'packages/ugk_coach_chat'
}
foreach ($package in $config.packages) {
  if ($sdkPackages.ContainsKey($package.name)) {
    $package.rootUri = [Uri]::new($sdkPackages[$package.name] + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
  }
}
foreach ($name in @('ugk_trainer_runtime', 'ugk_coach_chat')) {
  if (-not ($config.packages | Where-Object { $_.name -eq $name })) {
    $config.packages += @{
      name = $name
      rootUri = [Uri]::new($sdkPackages[$name] + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
      packageUri = 'lib/'
      languageVersion = '3.12'
    }
  }
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 20), $utf8)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'chat_capture_candidate.dart.txt') -Destination (Join-Path $snapshotRoot 'test/sdk_chat_candidate_capture_test.dart')
$environment = [ordered]@{
  baseline = $baselineRoot
  candidateDate = [DateTime]::Now.ToString('o')
  sdkBranch = (& git -C $sdkRoot branch --show-current)
  sdkHead = (& git -C $sdkRoot rev-parse HEAD)
  displayFixture = 'Canonical plans restore through the normal snapshot API; read-only suggestions are supplied by a test controller subclass. Waiting uses a pending FakeLlm.'
  flutterCommand = $flutterCommand
  frames = $Frames
  packages = @($config.packages | Where-Object { $_.name -in @('flutter', 'flutter_test', 'ugk_coach', 'ugk_coach_ui', 'ugk_trainer', 'ugk_trainer_runtime', 'ugk_coach_chat') })
}
[IO.File]::WriteAllText((Join-Path $candidateRoot 'candidate-environment.json'), ($environment | ConvertTo-Json -Depth 20), $utf8)
$env:CHAT_CAPTURE_OUTPUT = $candidateRoot
$env:CHAT_CAPTURE_BASELINE = $baselineRoot
$env:CHAT_CAPTURE_SDK_ROOT = $sdkRoot
$env:CHAT_CAPTURE_FRAMES = $Frames
Push-Location $snapshotRoot
try {
  & $flutterCommand test --no-pub --flavor internal --concurrency 1 -r expanded --dart-define=SMARTFIT_ALPHA_CARDS=true --dart-define=SMARTFIT_POSEHUB_PACK=true --dart-define=UGK_INTERNAL_MEDIA_PREVIEW=true test/sdk_chat_candidate_capture_test.dart *> (Join-Path $candidateRoot 'render.log')
  $captureExit = $LASTEXITCODE
} finally {
  Pop-Location
}
Get-Content -LiteralPath (Join-Path $candidateRoot 'render.log') -Tail 40
exit $captureExit
