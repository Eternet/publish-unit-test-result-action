param(
    [Parameter(Mandatory)][string] $PythonBinary,
    [Parameter(Mandatory)][string] $RequirementsFile,
    [Parameter(Mandatory)][string] $TempRoot,
    [Parameter(Mandatory)][string] $GitHubEnvFile
)

$ErrorActionPreference = 'Stop'
# Keep dependencies out of the runner's global Python and out of the checkout.
# A distinct environment also prevents another invocation from reusing stale packages.
$venvPath = Join-Path $TempRoot ("publish-test-results-" + [guid]::NewGuid().ToString('N'))
& $PythonBinary -m venv $venvPath
if ($LASTEXITCODE -ne 0) {
    throw "Cannot create the test-result publisher's Python environment (exit $LASTEXITCODE). Install Python with venv support."
}

$venvPython = Join-Path $venvPath 'Scripts/python.exe'
& $venvPython -m pip install --disable-pip-version-check --requirement $RequirementsFile
if ($LASTEXITCODE -ne 0) {
    throw "Cannot install the test-result publisher's pinned dependencies (exit $LASTEXITCODE)."
}

# Import the real publisher before exposing the environment to the next step.
# This does not execute its main function or call GitHub.
$publisherDirectory = Join-Path $PSScriptRoot '../python'
& $venvPython -c 'import sys; sys.path.insert(0, sys.argv[1]); import publish_test_results' $publisherDirectory
if ($LASTEXITCODE -ne 0) {
    throw "The test-result publisher cannot load in its Python environment (exit $LASTEXITCODE)."
}

"PYTHON_VENV=$venvPython" | Out-File -FilePath $GitHubEnvFile -Append -Encoding utf8
