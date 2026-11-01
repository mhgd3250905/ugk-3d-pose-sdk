param(
  [ValidateSet('Prepare', 'Dry', 'Live')]
  [string]$Mode = 'Prepare',
  [string]$SourceSnapshot = 'build/chat-extract-baseline/sf-3eb2a9e-v7/sf-source',
  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,
  [ValidateSet('on', 'off')]
  [string]$Thinking = 'on',
  [string]$FlutterCommand
)

$ErrorActionPreference = 'Stop'
$sdkRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot 'build')) + [IO.Path]::DirectorySeparatorChar
$runRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot $OutputDirectory))
if (-not $runRoot.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Live-run output must stay in the SDK build directory.'
}
if (Test-Path -LiteralPath $runRoot) {
  throw 'Choose a new output directory; previous runs are retained.'
}
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot $SourceSnapshot))
$sourceConfig = Join-Path $sourceRoot '.dart_tool/package_config.json'
if (-not (Test-Path -LiteralPath $sourceConfig)) {
  throw 'The read-only SF baseline snapshot and resolved package configuration are required.'
}
$chatRoot = Join-Path $sdkRoot 'packages/ugk_coach_chat'
$packages = Get-Content -Raw -LiteralPath $sourceConfig | ConvertFrom-Json -AsHashtable
$configUri = [Uri]::new([IO.Path]::GetFullPath($sourceConfig))
$sdkPackages = @{
  ugk_coach = $sdkRoot
  ugk_coach_ui = (Join-Path $sdkRoot 'packages/ugk_coach_ui')
  ugk_trainer = (Join-Path $sdkRoot 'packages/ugk_trainer')
  ugk_trainer_runtime = (Join-Path $sdkRoot 'packages/ugk_trainer_runtime')
  ugk_coach_chat = $chatRoot
}
$resolved = @()
foreach ($package in $packages.packages) {
  if ($sdkPackages.ContainsKey([string]$package.name)) {
    $package.rootUri = [Uri]::new($sdkPackages[$package.name] + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
  } elseif ($package.name -eq 'smartfit') {
    $package.rootUri = [Uri]::new($sourceRoot + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
  } else {
    $package.rootUri = [Uri]::new($configUri, [string]$package.rootUri).AbsoluteUri
  }
  $resolved += $package
}
foreach ($name in @('ugk_trainer_runtime', 'ugk_coach_chat')) {
  if ($name -notin @($resolved | ForEach-Object { $_.name })) {
    $resolved += @{
      name = $name
      rootUri = [Uri]::new($sdkPackages[$name] + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
      packageUri = 'lib/'
      languageVersion = '3.12'
    }
  }
}
$packages.packages = $resolved
if ([string]::IsNullOrWhiteSpace($FlutterCommand)) {
  $framework = $resolved | Where-Object { $_.name -eq 'flutter' }
  $frameworkRoot = ([Uri]$framework.rootUri).LocalPath.TrimEnd('/', '\')
  $flutterRoot = Split-Path -Parent (Split-Path -Parent $frameworkRoot)
  $FlutterCommand = Join-Path $flutterRoot 'bin/flutter.bat'
}
if (-not (Test-Path -LiteralPath $FlutterCommand)) {
  throw 'The full Flutter toolchain matching the SF baseline is unavailable.'
}
New-Item -ItemType Directory -Path $runRoot | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$testRoot = Join-Path $chatRoot ('build/chat-extract-live/' + (Split-Path -Leaf $runRoot))
if (Test-Path -LiteralPath $testRoot) {
  throw 'The temporary Flutter test host already exists; choose a new run name.'
}
New-Item -ItemType Directory -Path (Join-Path $testRoot '.dart_tool') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $testRoot 'test') -Force | Out-Null
$packages.packages += @{
  name = 'chat_extract_live_host'
  rootUri = [Uri]::new($testRoot + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
  packageUri = 'lib/'
  languageVersion = '3.12'
}
$packageConfig = Join-Path $testRoot '.dart_tool/package_config.json'
[IO.File]::WriteAllText($packageConfig, ($packages | ConvertTo-Json -Depth 20), $utf8)
$graph = Get-Content -Raw -LiteralPath (Join-Path $sourceRoot '.dart_tool/package_graph.json') | ConvertFrom-Json -AsHashtable
$moduleGraph = Get-Content -Raw -LiteralPath (Join-Path $chatRoot '.dart_tool/package_graph.json') | ConvertFrom-Json -AsHashtable
$graph.roots = @('chat_extract_live_host')
$graph.packages = @($graph.packages | Where-Object { $_.name -notin @('ugk_coach_chat', 'ugk_trainer_runtime') }) +
  @($moduleGraph.packages | Where-Object { $_.name -in @('ugk_coach_chat', 'ugk_trainer_runtime') })
foreach ($entry in $graph.packages) {
  if ($entry.name -eq 'ugk_trainer') { $entry.dependencies = @('ugk_trainer_runtime') }
}
$graph.packages += @{
  name = 'chat_extract_live_host'; version = '0.0.0'
  dependencies = @('flutter', 'ugk_coach_chat'); devDependencies = @('flutter_test')
}
[IO.File]::WriteAllText((Join-Path $testRoot '.dart_tool/package_graph.json'), ($graph | ConvertTo-Json -Depth 20), $utf8)
$chatYaml = $chatRoot.Replace('\', '/').Replace("'", "''")
$hostPubspec = @"
name: chat_extract_live_host
publish_to: none
environment:
  sdk: ^3.12.0
dependencies:
  flutter:
    sdk: flutter
  ugk_coach_chat:
    path: '$chatYaml'
dev_dependencies:
  flutter_test:
    sdk: flutter
"@
[IO.File]::WriteAllText((Join-Path $testRoot 'pubspec.yaml'), $hostPubspec, $utf8)
$sdkUri = [Uri]::new($sdkRoot + [IO.Path]::DirectorySeparatorChar).AbsoluteUri.TrimEnd('/')
$testTemplate = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'chat_extract_live_test.dart.txt')
$testCode = $testTemplate.Replace('__SDK_URI__', $sdkUri)
$testFile = Join-Path $testRoot 'test/chat_extract_live_test.dart'
[IO.File]::WriteAllText($testFile, $testCode, $utf8)
$environment = [ordered]@{
  mode = $Mode
  sourceCommit = '3eb2a9e88ef4d28e02f4cf306c1716d61baa7f10'
  sourceSnapshot = $sourceRoot
  moduleRoot = $chatRoot
  flutterCommand = [IO.Path]::GetFullPath($FlutterCommand)
  thinking = $Thinking
  timing = 'Same runtime SessionBuilder instance: SF AppTestContent rhythms, prep10; original SF SessionBuilder phase comparison'
  controller = 'CoachChatController; one fresh conversation; no fixed snapshot'
  inputs = @(
    '在家拉伸5分钟，入门，徒手和瑜伽垫，重点大腿内侧和髋部，无不适'
    '推荐几个拉大腿内侧的动作'
    '换一套，缩短到3分钟'
  )
  httpOptimizationTargets = @{ normal = 4; oneRepair = 6; deliveryGate = $false }
}
[IO.File]::WriteAllText((Join-Path $runRoot 'environment.json'), ($environment | ConvertTo-Json -Depth 12), $utf8)
if ($Mode -eq 'Prepare') {
  Write-Output "Prepared only; no Flutter/model execution: $runRoot"
  exit 0
}
$env:CHAT_EXTRACT_LIVE_MODE = $Mode.ToLowerInvariant()
$env:CHAT_EXTRACT_LIVE_OUTPUT = $runRoot
$env:CHAT_EXTRACT_LIVE_SOURCE = $sourceRoot
$env:CHAT_EXTRACT_LIVE_SDK = $sdkRoot
$env:CHAT_EXTRACT_LIVE_THINKING = $Thinking
Push-Location $testRoot
try {
  # Plain test() intentionally avoids TestWidgetsFlutterBinding's 400 HTTP stub.
  # All compilation/cache output stays in SDK-owned package/build directories.
  & $FlutterCommand "--packages=$packageConfig" test --no-pub --no-test-assets --concurrency 1 -r expanded $testFile *> (Join-Path $runRoot 'run.log')
  $runExit = $LASTEXITCODE
} finally {
  Pop-Location
}
Get-Content -LiteralPath (Join-Path $runRoot 'run.log') -Tail 32
if ($runExit -ne 0) { exit $runExit }
Write-Output "Completed $Mode run: $runRoot"
