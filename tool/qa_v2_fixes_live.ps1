param(
  [ValidateSet('Prepare', 'Dry', 'Live')]
  [string]$Mode = 'Prepare',
  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,
  [string]$SmartFitRoot = 'E:/AII-3D/3D-Sport-AI/Sport-Helper',
  [string]$FlareRoot = 'E:/AII-3D/3D-Body/app',
  [string]$Cases = '',
  [string]$FlutterCommand = 'flutter'
)

# Test-host outputs stay in SDK build/. Existing App configurations are read
# only; local SDK sources replace their pinned SDK packages for this run.
$ErrorActionPreference = 'Stop'
$sdkRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot 'build')) + [IO.Path]::DirectorySeparatorChar
$runRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot $OutputDirectory))
if (-not $runRoot.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'OutputDirectory must be inside SDK build/.'
}
if (Test-Path -LiteralPath $runRoot) { throw 'Use a new output directory; previous evidence is retained.' }
$sdkPackages = @{
  ugk_coach = $sdkRoot
  ugk_coach_chat = (Join-Path $sdkRoot 'packages/ugk_coach_chat')
  ugk_coach_ui = (Join-Path $sdkRoot 'packages/ugk_coach_ui')
  ugk_trainer = (Join-Path $sdkRoot 'packages/ugk_trainer')
  ugk_trainer_runtime = (Join-Path $sdkRoot 'packages/ugk_trainer_runtime')
}
$resolved = [ordered]@{}
$graphs = [ordered]@{}
foreach ($appRoot in @($SmartFitRoot, $FlareRoot)) {
  $configPath = Join-Path $appRoot '.dart_tool/package_config.json'
  $graphPath = Join-Path $appRoot '.dart_tool/package_graph.json'
  $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json -AsHashtable
  $configUri = [Uri]::new([IO.Path]::GetFullPath($configPath))
  foreach ($entry in $config.packages) {
    if (-not $resolved.Contains([string]$entry.name)) {
      $entry.rootUri = [Uri]::new($configUri, [string]$entry.rootUri).AbsoluteUri
      $resolved[[string]$entry.name] = $entry
    }
  }
  $graph = Get-Content -Raw -LiteralPath $graphPath | ConvertFrom-Json -AsHashtable
  foreach ($entry in $graph.packages) {
    if (-not $graphs.Contains([string]$entry.name)) { $graphs[[string]$entry.name] = $entry }
  }
}
foreach ($name in $sdkPackages.Keys) {
  $resolved[$name] = @{
    name = $name
    rootUri = [Uri]::new($sdkPackages[$name] + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
    packageUri = 'lib/'
    languageVersion = '3.12'
  }
}
$resolved['smartfit'].rootUri = [Uri]::new([IO.Path]::GetFullPath($SmartFitRoot) + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
$resolved['flare'].rootUri = [Uri]::new([IO.Path]::GetFullPath($FlareRoot) + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
New-Item -ItemType Directory -Path (Join-Path $runRoot 'host/.dart_tool') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $runRoot 'host/test') -Force | Out-Null
$hostRoot = Join-Path $runRoot 'host'
$resolved['qa_v2_fixes_live_host'] = @{
  name = 'qa_v2_fixes_live_host'
  rootUri = [Uri]::new($hostRoot + [IO.Path]::DirectorySeparatorChar).AbsoluteUri
  packageUri = 'lib/'
  languageVersion = '3.12'
}
$graphs['qa_v2_fixes_live_host'] = @{
  name = 'qa_v2_fixes_live_host'; version = '0.0.0'
  dependencies = @('flutter', 'smartfit', 'flare', 'ugk_coach_chat', 'ugk_trainer_runtime')
  devDependencies = @('flutter_test')
}
$utf8 = [Text.UTF8Encoding]::new($false)
$packageConfig = Join-Path $hostRoot '.dart_tool/package_config.json'
[IO.File]::WriteAllText($packageConfig, (@{configVersion=2; packages=@($resolved.Values)} | ConvertTo-Json -Depth 20), $utf8)
[IO.File]::WriteAllText((Join-Path $hostRoot '.dart_tool/package_graph.json'),
  (@{configVersion=1; roots=@('qa_v2_fixes_live_host'); packages=@($graphs.Values)} | ConvertTo-Json -Depth 20), $utf8)
[IO.File]::WriteAllText((Join-Path $hostRoot 'pubspec.yaml'), @"
name: qa_v2_fixes_live_host
publish_to: none
environment:
  sdk: ^3.12.0
dependencies:
  flutter:
    sdk: flutter
  ugk_coach_chat:
    path: '$($sdkPackages.ugk_coach_chat.Replace('\','/'))'
dev_dependencies:
  flutter_test:
    sdk: flutter
"@, $utf8)
$sdkUri = [Uri]::new($sdkRoot + [IO.Path]::DirectorySeparatorChar).AbsoluteUri.TrimEnd('/')
$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'qa_v2_fixes_live_test.dart.txt') -Raw
$testFile = Join-Path $hostRoot 'test/qa_v2_fixes_live_test.dart'
[IO.File]::WriteAllText($testFile, $template.Replace('__SDK_URI__', $sdkUri), $utf8)
[IO.File]::WriteAllText((Join-Path $runRoot 'environment.json'), (@{
  mode=$Mode; sdk=$sdkRoot; smartfit=$SmartFitRoot; flare=$FlareRoot
  model='deepseek-v4.1-flash'; reasoning_effort='max'; thinking=@{type='enabled'}
  sdkSource=(& git -C $sdkRoot rev-parse HEAD)
  noOuterRetries=$true; emulator=$false; device=$false; cases=$Cases
} | ConvertTo-Json -Depth 6), $utf8)
if ($Mode -eq 'Prepare') { Write-Output "Prepared; no model requests: $runRoot"; exit 0 }
$env:QA_V2_FIXES_MODE = $Mode.ToLowerInvariant()
$env:QA_V2_FIXES_OUTPUT = $runRoot
$env:QA_V2_FIXES_SDK = $sdkRoot
$env:QA_V2_FIXES_SMARTFIT = [IO.Path]::GetFullPath($SmartFitRoot)
$env:QA_V2_FIXES_FLARE = [IO.Path]::GetFullPath($FlareRoot)
$env:QA_V2_FIXES_CASES = $Cases
Push-Location $hostRoot
try {
  & $FlutterCommand "--packages=$packageConfig" test --no-pub --no-test-assets --concurrency 1 -r expanded $testFile *> (Join-Path $runRoot 'run.log')
  $runExit = $LASTEXITCODE
} finally { Pop-Location }
Get-Content -LiteralPath (Join-Path $runRoot 'run.log') -Tail 40
if ($runExit -ne 0) { exit $runExit }
Write-Output "Completed ${Mode}: $runRoot"
