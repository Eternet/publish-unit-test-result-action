param([string] $PythonBin = (Get-Command python).Source)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Prepare-PublisherPython.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('publisher-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$requirements = Join-Path $testRoot 'empty.txt'
Set-Content -LiteralPath $requirements -Value ''
function Assert-ThrowsContaining([scriptblock] $Action, [string] $Expected) {
    try { & $Action } catch {
        if ($_.Exception.Message.Contains($Expected)) { return }
        throw
    }
    throw "Expected failure: $Expected"
}

# A failed Python process must stop setup, never fall back to the global interpreter.
$failedPython = Join-Path $testRoot 'failed-python.ps1'
Set-Content -LiteralPath $failedPython -Value '$global:LASTEXITCODE = 42'
Assert-ThrowsContaining { New-PublisherPythonEnvironment $failedPython $requirements $testRoot } 'creation failed (exit 42)'
Write-Host 'PASS SetupFailureStopsBeforeDependencyInstall'

# Two successful invocations get distinct, real venvs and do not install globally.
$first = New-PublisherPythonEnvironment $PythonBin $requirements $testRoot
$second = New-PublisherPythonEnvironment $PythonBin $requirements $testRoot
if ($first -eq $second) { throw 'Invocations reused a virtual environment.' }
foreach ($python in @($first, $second)) {
    if (-not $python.StartsWith($testRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Environment escaped its temporary root.' }
    & $python -c 'import sys; assert sys.prefix != sys.base_prefix'
    if ($LASTEXITCODE -ne 0) { throw 'Not an isolated environment.' }
}
Write-Host 'PASS SeparateInvocationsUseDistinctRealEnvironments'

# An invalid local requirements file fails pip without using an index/network.
$badRequirements = Join-Path $testRoot 'invalid.txt'
Set-Content -LiteralPath $badRequirements -Value 'not a valid requirement !!!!'
Assert-ThrowsContaining { New-PublisherPythonEnvironment $PythonBin $badRequirements $testRoot } 'dependency installation failed'
Write-Host 'PASS DependencyFailureStopsBeforePublisher'

Assert-ThrowsContaining { New-PublisherPythonEnvironment $PythonBin "$testRoot/missing.txt" $testRoot } 'requirements file is missing'
Write-Host 'PASS MissingRequirementsFailClosed'
$global:LASTEXITCODE = 0
