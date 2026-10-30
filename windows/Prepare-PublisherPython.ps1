function New-PublisherPythonEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PythonBin,
        [Parameter(Mandatory)][string] $RequirementsPath,
        [Parameter(Mandatory)][string] $RunnerTemp
    )

    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path -LiteralPath $PythonBin -PathType Leaf)) { throw 'Python executable is missing.' }
    if (-not (Test-Path -LiteralPath $RequirementsPath -PathType Leaf)) { throw 'Publisher requirements file is missing.' }
    if (-not (Test-Path -LiteralPath $RunnerTemp -PathType Container)) { throw 'Runner temporary directory is missing.' }

    $venv = Join-Path (Resolve-Path -LiteralPath $RunnerTemp).Path ('publish-test-results-' + [guid]::NewGuid().ToString('N'))
    & $PythonBin -m venv $venv | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Publisher virtual environment creation failed (exit $LASTEXITCODE)." }

    $python = Join-Path $venv 'Scripts/python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Publisher virtual environment has no Python executable.' }
    & $python -m pip --isolated install --disable-pip-version-check -r $RequirementsPath | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Publisher dependency installation failed (exit $LASTEXITCODE)." }

    return $python
}
