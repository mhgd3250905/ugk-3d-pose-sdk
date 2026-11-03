param(
  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,
  [string]$AiTagsDirectory,
  [string]$PoseHubRepository = 'E:/AII-3D/3D-Pose-Hub',
  [string]$AiTagsCommit = '5d17c24',
  [string]$FlutterCommand = 'flutter'
)

# Explicit opt-in real-model UI smoke. Credentials use eval_api_config.dart;
# this launcher never reads or prints them. No emulator/device is started.
$ErrorActionPreference = 'Stop'
$sdkRoot = Split-Path -Parent $PSScriptRoot
$chatRoot = Join-Path $sdkRoot 'packages/ugk_coach_chat'
$buildRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot 'build')) + [IO.Path]::DirectorySeparatorChar
$runRoot = [IO.Path]::GetFullPath((Join-Path $sdkRoot $OutputDirectory))
if (-not $runRoot.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Live-run output must stay inside SDK build/.'
}
if (Test-Path -LiteralPath $runRoot) {
  throw 'Choose a new output directory; previous evidence is retained.'
}
New-Item -ItemType Directory -Path $runRoot | Out-Null
if ([string]::IsNullOrWhiteSpace($AiTagsDirectory)) {
  $archivePath = Join-Path $runRoot 'ai-tags-source.tar'
  & git -C $PoseHubRepository archive --format=tar --output=$archivePath $AiTagsCommit catalog/ai-tags/actions
  if ($LASTEXITCODE -ne 0) { throw 'Cannot read the requested Pose-Hub tag snapshot.' }
  & tar -xf $archivePath -C $runRoot
  if ($LASTEXITCODE -ne 0) { throw 'Cannot extract tags into build output.' }
  $AiTagsDirectory = Join-Path $runRoot 'catalog/ai-tags/actions'
}
if (-not (Test-Path -LiteralPath $AiTagsDirectory -PathType Container)) {
  throw 'App-supplied aiTags directory is unavailable.'
}
$testRoot = Join-Path $chatRoot ('build/qa-v2-live/' + (Split-Path -Leaf $runRoot))
if (Test-Path -LiteralPath $testRoot) {
  throw 'Temporary test already exists; choose a new run name.'
}
New-Item -ItemType Directory -Path $testRoot | Out-Null
$sdkUri = [Uri]::new($sdkRoot + [IO.Path]::DirectorySeparatorChar).AbsoluteUri.TrimEnd('/')
$template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'coach_chat_qa_v2_live_test.dart.txt')
$testFile = Join-Path $testRoot 'coach_chat_qa_v2_live_test.dart'
[IO.File]::WriteAllText($testFile, $template.Replace('__SDK_URI__', $sdkUri), [Text.UTF8Encoding]::new($false))
$env:COACH_CHAT_QA_V2_LIVE_OUTPUT = $runRoot
$env:COACH_CHAT_QA_V2_LIVE_SDK = $sdkRoot
$env:AI_TAGS_DIR = [IO.Path]::GetFullPath($AiTagsDirectory)
Push-Location $chatRoot
try {
  & $FlutterCommand test --no-pub --no-test-assets --concurrency 1 -r expanded $testFile *> (Join-Path $runRoot 'run.log')
  $runExit = $LASTEXITCODE
} finally {
  Pop-Location
}
Get-Content -LiteralPath (Join-Path $runRoot 'run.log') -Tail 35
if ($runExit -ne 0) { exit $runExit }
Write-Output "Real-model chat-page smoke passed: $runRoot"
