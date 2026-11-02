param([Parameter(Mandatory)][string] $PythonBinary)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("publisher-bootstrap-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$setup = Join-Path $PSScriptRoot 'setup-python.ps1'
$requirements = Join-Path $PSScriptRoot '../python/requirements-post-3.8.txt'

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

# Reproduce the incident without depending on what the host happens to have installed.
& $PythonBinary -m venv --without-pip (Join-Path $testRoot 'bare')
Assert-True ($LASTEXITCODE -eq 0) 'Could not create the bare reproduction interpreter.'
$barePython = Join-Path $testRoot 'bare/Scripts/python.exe'
& $barePython -c 'import importlib.util; assert importlib.util.find_spec("github") is None; assert importlib.util.find_spec("pip") is None'
Assert-True ($LASTEXITCODE -eq 0) 'Reproduction interpreter unexpectedly has publisher dependencies.'
$successfulEnv = Join-Path $testRoot 'success.env'
& $setup -PythonBinary $barePython -RequirementsFile $requirements -TempRoot $testRoot -GitHubEnvFile $successfulEnv
$venvPython = (Get-Content $successfulEnv | Where-Object { $_.StartsWith('PYTHON_VENV=') }).Substring(12)
Assert-True (Test-Path $venvPython) 'Bootstrap did not expose an existing interpreter.'
Assert-True ($venvPython -ne $barePython) 'Bootstrap modified the input interpreter instead of isolating dependencies.'
& $venvPython -c 'import sys; sys.path.insert(0, sys.argv[1]); import publish_test_results; import github, lxml, psutil, humanize, junitparser; assert sys.prefix != sys.base_prefix' (Join-Path $PSScriptRoot '../python')
Assert-True ($LASTEXITCODE -eq 0) 'The real publisher did not import from the isolated environment.'
& $barePython -c 'import importlib.util; assert importlib.util.find_spec("github") is None; assert importlib.util.find_spec("pip") is None'
Assert-True ($LASTEXITCODE -eq 0) 'Bootstrap polluted the input interpreter.'
Write-Output 'PASS CleanInterpreter_LoadsRealPublisher_WithoutChangingInputInterpreter'

# A real failed pip process must fail the step and must never advertise a ready environment.
$badRequirements = Join-Path $testRoot 'invalid-requirements.txt'
"--no-index`npublisher-bootstrap-nonexistent-fixture==0" | Set-Content $badRequirements
$failedEnv = Join-Path $testRoot 'failed.env'
$caught = $false
try {
    & $setup -PythonBinary $barePython -RequirementsFile $badRequirements -TempRoot $testRoot -GitHubEnvFile $failedEnv
} catch {
    $caught = $_.Exception.Message -like '*Cannot install*pinned dependencies*'
}
Assert-True $caught 'A failed dependency install did not stop bootstrap.'
Assert-True (-not (Test-Path $failedEnv)) 'A failed dependency install exposed an unusable environment.'
Write-Output 'PASS FailedDependencyInstall_FailsClosed_WithoutPublishingEnvironment'

# Also exercise a native interpreter failure, independently of pip.
$failingPython = Join-Path $testRoot 'failed-python.cmd'
'@exit /b 37' | Set-Content $failingPython
$creationEnv = Join-Path $testRoot 'creation.env'
$caught = $false
try {
    & $setup -PythonBinary $failingPython -RequirementsFile $requirements -TempRoot $testRoot -GitHubEnvFile $creationEnv
} catch {
    $caught = $_.Exception.Message -like '*Cannot create*exit 37*'
}
Assert-True $caught 'A native venv failure did not stop bootstrap.'
Assert-True (-not (Test-Path $creationEnv)) 'A failed environment creation exposed an interpreter.'
Write-Output 'PASS FailedEnvironmentCreation_PreservesNativeFailure_WithoutGlobalFallback'
# The expected native failure above must not become the enclosing Actions shell's exit code.
exit 0
