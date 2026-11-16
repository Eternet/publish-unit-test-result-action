param([string] $PythonBin = (Get-Command python).Source)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Prepare-PublisherPython.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('publisher-tests-' + [guid]::NewGuid().ToString('N'))
$cache = Join-Path $testRoot 'cache'
New-Item -ItemType Directory -Path $testRoot | Out-Null
$requirements = Join-Path $testRoot 'empty.txt'
Set-Content -LiteralPath $requirements -Value ''
$common = @{ RunnerTemp = $testRoot; CacheRoot = $cache; ImportCheck = 'import json' }
function Assert-ThrowsContaining([scriptblock] $Action, [string] $Expected) {
    try { & $Action } catch {
        if ($_.Exception.Message.Contains($Expected)) { return }
        throw
    }
    throw "Expected failure: $Expected"
}

try {
    # A failed Python process must stop setup, never fall back to the global interpreter.
    $failedPython = Join-Path $testRoot 'failed-python.ps1'
    Set-Content -LiteralPath $failedPython -Value '$global:LASTEXITCODE = 42'
    Assert-ThrowsContaining { New-PublisherPythonEnvironment $failedPython $requirements @common } 'identification failed (exit 42)'
    Write-Host 'PASS SetupFailureStopsBeforeDependencyInstall'

    # The environment is a real venv inside the cache, and the next job reuses it instead of installing again.
    $first = New-PublisherPythonEnvironment $PythonBin $requirements @common
    if (-not $first.StartsWith($cache + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Environment escaped its cache root.' }
    & $first -c 'import sys; assert sys.prefix != sys.base_prefix'
    if ($LASTEXITCODE -ne 0) { throw 'Not an isolated environment.' }
    $stamp = (Get-Item -LiteralPath $first).LastWriteTimeUtc
    $second = New-PublisherPythonEnvironment $PythonBin $requirements @common
    if ($second -ne $first -or (Get-Item -LiteralPath $second).LastWriteTimeUtc -ne $stamp) { throw 'A verified environment was not reused.' }
    if (@(Get-ChildItem -LiteralPath $cache -Directory -Filter 'staging-*').Count) { throw 'A staging folder was left behind.' }
    Write-Host 'PASS VerifiedEnvironmentIsReused'

    # Different requirements get a different environment.
    $other = Join-Path $testRoot 'other.txt'
    Set-Content -LiteralPath $other -Value '# other'
    if ((New-PublisherPythonEnvironment $PythonBin $other @common) -eq $first) { throw 'Different requirements shared an environment.' }
    Write-Host 'PASS RequirementsChangeUsesNewEnvironment'

    # A cached environment that no longer imports its dependencies is never used.
    $broken = New-PublisherPythonEnvironment $PythonBin $requirements -RunnerTemp $testRoot -CacheRoot $cache -ImportCheck 'import json'
    $brokenCheck = 'import module_that_does_not_exist'
    Assert-ThrowsContaining { New-PublisherPythonEnvironment $PythonBin $requirements -RunnerTemp $testRoot -CacheRoot $cache -ImportCheck $brokenCheck } 'not importable'
    if (-not (Test-Path -LiteralPath $broken)) { throw 'The shared environment was removed while it may be in use.' }
    Write-Host 'PASS UnusableEnvironmentFailsClosed'

    # An invalid local requirements file fails pip without using an index/network.
    $badRequirements = Join-Path $testRoot 'invalid.txt'
    Set-Content -LiteralPath $badRequirements -Value 'not a valid requirement !!!!'
    Assert-ThrowsContaining { New-PublisherPythonEnvironment $PythonBin $badRequirements @common } 'dependency installation failed'
    Write-Host 'PASS DependencyFailureStopsBeforePublisher'

    Assert-ThrowsContaining { New-PublisherPythonEnvironment $PythonBin "$testRoot/missing.txt" @common } 'requirements file is missing'
    Write-Host 'PASS MissingRequirementsFailClosed'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$global:LASTEXITCODE = 0
