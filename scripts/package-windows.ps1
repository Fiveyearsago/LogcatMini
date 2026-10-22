$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path $PSScriptRoot -Parent
$PackageName = "LogcatMini-0.2.0-Windows-x64"
$StagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("LogcatMini-" + [guid]::NewGuid())
$PackageDir = Join-Path $StagingDir $PackageName
$Output = Join-Path $ProjectDir ("dist\" + $PackageName + ".zip")
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
python (Join-Path $ProjectDir "scripts/prepare-windows-recording.py")
if ($LASTEXITCODE -ne 0) { throw "Recorder preparation failed" }
Push-Location (Join-Path $ProjectDir "windows")
try {
    dotnet run --project LogcatMini.Checks -c Release
    if ($LASTEXITCODE -ne 0) { throw "Core checks failed" }
    dotnet run --project LogcatMini.UiChecks -c Release
    if ($LASTEXITCODE -ne 0) { throw "UI checks failed" }
    dotnet publish LogcatMini.Desktop -c Release -r win-x64 --self-contained true -p:PublishTrimmed=false -p:RestoreLockedMode=true -o $PackageDir
    if ($LASTEXITCODE -ne 0) { throw "Publish failed" }
    Copy-Item (Join-Path $ProjectDir "windows\使用说明.txt") $PackageDir
    Copy-Item (Join-Path $ProjectDir "windows\licenses") $PackageDir -Recurse
    Get-ChildItem $PackageDir -Filter *.pdb -Recurse | Remove-Item
    New-Item -ItemType Directory -Path (Split-Path $Output) -Force | Out-Null
    Compress-Archive -Path $PackageDir -DestinationPath $Output -Force
    $Hash = (Get-FileHash $Output -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $PackageName.zip" | Set-Content ($Output + ".sha256") -Encoding ascii
    Write-Host $Output
    Write-Host "SHA256 $Hash"
} finally {
    Pop-Location
    if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
}
