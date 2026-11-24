# MotionAI - one-time Android SDK setup + first project check.
# Run from PowerShell:  powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Documents\MotionAI\setup-android.ps1"

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $MyInvocation.MyCommand.Path
Start-Transcript -Path "$project\setup-log.txt" -Force | Out-Null

$sdk = 'C:\Android'
$zipName = 'commandlinetools-win-15859902_latest.zip'
$zipUrl = "https://dl.google.com/android/repository/$zipName"
$zipSha = '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a'

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# 1. Java 17 (needed by the Android tools and Gradle)
Step 'Java 17'
$jdk = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $jdk) {
    winget install --id Microsoft.OpenJDK.17 -e --accept-package-agreements
    $jdk = Get-ChildItem 'C:\Program Files\Microsoft' -Directory -Filter 'jdk-17*' | Select-Object -First 1
}
if (-not $jdk) { throw 'Java 17 was not found after install.' }
$env:JAVA_HOME = $jdk.FullName
$env:Path = "$($jdk.FullName)\bin;$env:Path"
[Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk.FullName, 'User')
Write-Host "Java: $($jdk.FullName)"

# 2. Android command-line tools
Step 'Android command-line tools'
$sdkmanager = "$sdk\cmdline-tools\latest\bin\sdkmanager.bat"
if (-not (Test-Path $sdkmanager)) {
    $zip = "$env:TEMP\$zipName"
    Write-Host "Downloading $zipName (about 156 MB)..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $zipSha) { throw "Checksum mismatch for $zipName - download is corrupted." }
    Expand-Archive $zip -DestinationPath "$sdk\temp" -Force
    New-Item -ItemType Directory -Force "$sdk\cmdline-tools" | Out-Null
    Move-Item "$sdk\temp\cmdline-tools" "$sdk\cmdline-tools\latest"
    Remove-Item "$sdk\temp" -Recurse -Force
    Remove-Item $zip -Force
}
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdk, 'User')
$env:ANDROID_HOME = $sdk

# Native tools write progress to stderr; don't treat that as a failure.
$ErrorActionPreference = 'Continue'

# 3. SDK packages
Step 'Android SDK packages (accept the licenses when asked: type y)'
& $sdkmanager --sdk_root=$sdk 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'

# 4. Connect Flutter
Step 'Flutter configuration'
flutter config --android-sdk $sdk
flutter config --jdk-dir $jdk.FullName
Step 'Android licenses (type y for each)'
flutter doctor --android-licenses
flutter doctor

# 5. Project
Step 'MotionAI project'
Set-Location $project
flutter create --org com.mohitflix --project-name motionai --platforms=android,ios .
flutter pub get
flutter analyze *> "$project\analyze-output.txt"
Get-Content "$project\analyze-output.txt"
flutter test *> "$project\test-output.txt"
Get-Content "$project\test-output.txt" -Tail 15

Stop-Transcript | Out-Null
Write-Host "`nDone. Tell Claude 'setup finished' - results are saved in the MotionAI folder." -ForegroundColor Green
