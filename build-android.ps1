param(
  [string]$ToolsRoot = 'C:\Users\eddyd\Documents\Codex\tools',
  [string]$AndroidSdk = 'C:\Users\eddyd\AppData\Local\Android\sdk',
  [string]$JavaHome = 'C:\Program Files\Android\Android Studio\jbr',
  [switch]$SkipPub
)
$ErrorActionPreference = 'Stop'
$env:JAVA_HOME = $JavaHome
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:PUB_CACHE = Join-Path $ToolsRoot 'pub-cache'
if (!$env:GRADLE_USER_HOME) { $env:GRADLE_USER_HOME = Join-Path $env:USERPROFILE '.gradle' }
$bundledGit = 'C:\Users\eddyd\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd'
$env:PATH = "$ToolsRoot\flutter\bin;$env:JAVA_HOME\bin;$bundledGit;" + $env:PATH
Push-Location $PSScriptRoot
try {
  if (!$SkipPub) {
    & "$ToolsRoot\flutter\bin\flutter.bat" pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed' }
  }
  & "$ToolsRoot\flutter\bin\flutter.bat" build apk --debug --no-pub
  if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
  Write-Output (Join-Path $PSScriptRoot 'build\app\outputs\flutter-apk\app-debug.apk')
} finally { Pop-Location }
