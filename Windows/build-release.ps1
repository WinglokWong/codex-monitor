param([switch]$SkipTests)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Push-Location $PSScriptRoot
try {
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    $artifacts = Join-Path $PSScriptRoot 'artifacts'
    $publish = Join-Path $artifacts 'publish'
    New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
    dotnet build CodexMonitor.Tests/CodexMonitor.Tests.csproj -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
    if (-not $SkipTests) {
        dotnet run --project CodexMonitor.Tests/CodexMonitor.Tests.csproj -c Release --no-build 2>&1 |
            Tee-Object -FilePath (Join-Path $artifacts 'test-results.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Windows tests failed.' }
    }
    dotnet publish CodexMonitor.Windows/CodexMonitor.Windows.csproj -c Release -r win-x64 --self-contained true `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o $publish
    if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
    $executable = Join-Path $publish 'CodexMonitor.exe'
    $renderPath = Join-Path $artifacts 'ui-preview.png'
    $start = [System.Diagnostics.ProcessStartInfo]::new($executable)
    $start.UseShellExecute = $false
    $start.ArgumentList.Add('--render-smoke')
    $start.ArgumentList.Add($renderPath)
    $process = [System.Diagnostics.Process]::Start($start)
    if (-not $process.WaitForExit(30000)) { $process.Kill($true); throw 'UI render smoke test timed out.' }
    if ($process.ExitCode -ne 0 -or -not (Test-Path $renderPath)) {
        if (Test-Path "$renderPath.error.txt") { Get-Content "$renderPath.error.txt" | Write-Host }
        throw 'UI render smoke test failed.'
    }
    Copy-Item README.md (Join-Path $publish 'README-Windows.md')
    # Include the licenses shipped with the framework runtime packs we redistribute.
    $licenses = Join-Path $publish 'licenses'
    New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    $nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget/packages' }
    foreach ($package in @('microsoft.netcore.app.runtime.win-x64', 'microsoft.windowsdesktop.app.runtime.win-x64')) {
        $root = Join-Path $nugetRoot $package
        if (Test-Path $root) {
            Get-ChildItem $root -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|THIRD.PARTY)' } | ForEach-Object {
                Copy-Item $_.FullName (Join-Path $licenses ($package + '-' + $_.Name)) -Force
            }
        }
    }
    [xml]$properties = Get-Content Directory.Build.props
    $version = [string]$properties.Project.PropertyGroup.Version
    $name = "Codex-Monitor-$version-windows-x64.zip"
    $zip = Join-Path $artifacts $name
    Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -Force -CompressionLevel Optimal
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $name" | Set-Content (Join-Path $artifacts 'SHA256SUMS.txt') -Encoding utf8
    Write-Host "Packaged $zip"
} finally {
    Pop-Location
}
