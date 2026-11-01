param(
  [string]$SourceRepository = 'E:/AII-3D/3D-Sport-AI/Sport-Helper-coach-ui-kit',
  [string]$SourceCommit = '3eb2a9e88ef4d28e02f4cf306c1716d61baa7f10',
  [string]$OutputDirectory = 'build/chat-extract-baseline/sf-3eb2a9e',
  [string]$FlutterCommand,
  [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
$sdkRoot = Split-Path -Parent $PSScriptRoot
$sdkBuild = [IO.Path]::GetFullPath((Join-Path $sdkRoot 'build')) + [IO.Path]::DirectorySeparatorChar
$captureRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot $OutputDirectory))
if (-not $captureRoot.StartsWith($sdkBuild, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Capture output must be inside this SDK build directory.'
}
if (Test-Path -LiteralPath $captureRoot) {
  throw 'Choose a new output directory; captures are never overwritten.'
}
$sourceRoot = (Resolve-Path -LiteralPath $SourceRepository).Path
$sourceConfig = Join-Path $sourceRoot '.dart_tool/package_config.json'
if (-not (Test-Path -LiteralPath $sourceConfig)) {
  throw 'The read-only SF source needs an existing resolved package_config.json.'
}
$sourceState = & git -C $sourceRoot status --porcelain
if ($LASTEXITCODE -ne 0) { throw 'Cannot read SF Git state.' }
$sourceRevision = & git -C $sourceRoot rev-parse $SourceCommit
if ($LASTEXITCODE -ne 0) { throw 'SF source commit is unavailable.' }
New-Item -ItemType Directory -Path $captureRoot | Out-Null
$snapshotRoot = Join-Path $captureRoot 'sf-source'
New-Item -ItemType Directory -Path $snapshotRoot | Out-Null
$archive = Join-Path $captureRoot 'sf-source.tar'
& git -C $sourceRoot archive --format=tar "--output=$archive" $SourceCommit lib test assets ios/Runner/Assets.xcassets/AppIconB.appiconset/Icon-App-60x60@3x.png pubspec.yaml pubspec.lock analysis_options.yaml .metadata
if ($LASTEXITCODE -ne 0) { throw 'SF source archive failed.' }
& tar -xf $archive -C $snapshotRoot
if ($LASTEXITCODE -ne 0) { throw 'SF source archive extraction failed.' }
# The original App keeps downloaded/bundled image bytes outside Git. Copy the
# existing payload read-only; its production resolver still checks the index.
$imageRoot = Join-Path $sourceRoot 'assets/posehub/images'
if (-not (Test-Path -LiteralPath $imageRoot)) {
  throw 'SF bundled image payload is not present; ask SF Agent to provision it.'
}
Copy-Item -LiteralPath $imageRoot -Destination (Join-Path $snapshotRoot 'assets/posehub') -Recurse
$dartTool = Join-Path $snapshotRoot '.dart_tool'
New-Item -ItemType Directory -Path $dartTool | Out-Null
$packages = Get-Content -Raw -LiteralPath $sourceConfig | ConvertFrom-Json -AsHashtable
$sourceConfigUri = [Uri]::new([IO.Path]::GetFullPath($sourceConfig))
foreach ($package in $packages.packages) {
  $package.rootUri = if ($package.name -eq 'smartfit') {
    [Uri]::new($snapshotRoot + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
  } else {
    [Uri]::new($sourceConfigUri, [string]$package.rootUri).AbsoluteUri
  }
}
if ([string]::IsNullOrWhiteSpace($FlutterCommand)) {
  $framework = $packages.packages | Where-Object { $_.name -eq 'flutter' }
  $frameworkRoot = ([Uri]$framework.rootUri).LocalPath.TrimEnd('/', '\')
  $flutterSdkRoot = Split-Path -Parent (Split-Path -Parent $frameworkRoot)
  $FlutterCommand = Join-Path $flutterSdkRoot 'bin/flutter.bat'
}
if (-not (Test-Path -LiteralPath $FlutterCommand)) {
  throw 'The full Flutter toolchain matching the SF resolved framework is unavailable.'
}
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $dartTool 'package_config.json'), ($packages | ConvertTo-Json -Depth 20), $utf8)
foreach ($relative in @('.dart_tool/package_graph.json', '.flutter-plugins-dependencies')) {
  $sourceFile = Join-Path $sourceRoot $relative
  if (Test-Path -LiteralPath $sourceFile) {
    Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $snapshotRoot $relative)
  }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'chat_capture_sf_baseline.dart.txt') -Destination (Join-Path $snapshotRoot 'test/sdk_chat_baseline_capture_test.dart')
$environment = [ordered]@{
  sourceCommit = $sourceRevision
  captureDate = [DateTime]::Now.ToString('o')
  flutterCommand = [IO.Path]::GetFullPath($FlutterCommand)
  renderer = 'Flutter widget-test software renderer (flutter_tester)'
  viewport = @{width = 390; height = 844; devicePixelRatio = 1; topInset = 24; bottomInset = 24}
  font = 'NotoSansSC from SF assets/fonts/NotoSansSC.ttf'
  clock = '2026-10-30T12:00:00'
  animation = 'normal motion; static original 48-star field'
  flavor = 'internal'
  defines = @('SMARTFIT_ALPHA_CARDS=true', 'SMARTFIT_POSEHUB_PACK=true', 'UGK_INTERNAL_MEDIA_PREVIEW=true')
  network = 'no live model or media requests'
  sourceWorkingTreeState = @($sourceState)
  packages = @($packages.packages | Where-Object { $_.name -in @('flutter', 'ugk_coach', 'ugk_coach_ui', 'ugk_trainer') })
}
[IO.File]::WriteAllText((Join-Path $captureRoot 'environment.json'), ($environment | ConvertTo-Json -Depth 20), $utf8)
& $FlutterCommand --version | Out-File -LiteralPath (Join-Path $captureRoot 'flutter-version.txt') -Encoding utf8
if ($PrepareOnly) { Write-Output $snapshotRoot; exit 0 }
$env:CHAT_CAPTURE_OUTPUT = $captureRoot
Push-Location $snapshotRoot
try {
  & $FlutterCommand test --no-pub --flavor internal --concurrency 1 -r expanded --dart-define=SMARTFIT_ALPHA_CARDS=true --dart-define=SMARTFIT_POSEHUB_PACK=true --dart-define=UGK_INTERNAL_MEDIA_PREVIEW=true test/sdk_chat_baseline_capture_test.dart *> (Join-Path $captureRoot 'render.log')
  $captureExit = $LASTEXITCODE
} finally {
  Pop-Location
}
Get-Content -LiteralPath (Join-Path $captureRoot 'render.log') -Tail 30
if ($captureExit -ne 0) { exit $captureExit }
$afterState = & git -C $sourceRoot status --porcelain
if (($sourceState -join "`n") -ne ($afterState -join "`n")) { throw 'SF source working tree changed during capture.' }
Write-Output "Capture complete: $captureRoot"
