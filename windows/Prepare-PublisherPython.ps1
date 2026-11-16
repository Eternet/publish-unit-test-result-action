function Test-PublisherPythonEnvironment {
    [CmdletBinding()]
    param([string] $Root, [string] $Key, [string] $ImportCheck)

    $python = Join-Path $Root 'Scripts/python.exe'
    $marker = Join-Path $Root 'eternet-publisher-ready.txt'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf) -or -not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne $Key) { return $false }
    & $python -c "import sys; assert sys.prefix != sys.base_prefix; $ImportCheck" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function New-PublisherPythonEnvironment {
    <#
        Returns the python.exe of a virtual environment that has the publisher requirements. The environment depends only
        on the selected interpreter and the requirements file, never on packages installed in the runner's Python.

        Environments are kept under CacheRoot (by default %LOCALAPPDATA%, which persists across jobs on the Eternet
        runners) and keyed by interpreter path, interpreter version and requirements content, so a job normally only
        verifies an existing environment instead of downloading packages again. A new environment is built in a staging
        folder and published with an atomic rename; concurrent jobs never share a half-built environment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PythonBin,
        [Parameter(Mandatory)][string] $RequirementsPath,
        [Parameter(Mandatory)][string] $RunnerTemp,
        [string] $CacheRoot = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'eternet-test-result-publisher' } else { '' }),
        [string] $ImportCheck = 'import github, humanize, junitparser, lxml, psutil'
    )

    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path -LiteralPath $PythonBin -PathType Leaf)) { throw 'Python executable is missing.' }
    if (-not (Test-Path -LiteralPath $RequirementsPath -PathType Leaf)) { throw 'Publisher requirements file is missing.' }
    if (-not (Test-Path -LiteralPath $RunnerTemp -PathType Container)) { throw 'Runner temporary directory is missing.' }

    $identity = & $PythonBin -c 'import sys; print(sys.executable); print(sys.version)'
    if ($LASTEXITCODE -ne 0) { throw "Publisher Python identification failed (exit $LASTEXITCODE)." }
    $material = "eternet-publisher-v1`n$($identity -join "`n")`n" + [IO.File]::ReadAllText((Resolve-Path -LiteralPath $RequirementsPath).Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material)) | Select-Object -First 12 | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }

    if (-not $CacheRoot) { $CacheRoot = Join-Path (Resolve-Path -LiteralPath $RunnerTemp).Path 'publisher-python' }
    try { New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null }
    catch { $CacheRoot = Join-Path (Resolve-Path -LiteralPath $RunnerTemp).Path 'publisher-python'; New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null }

    $final = Join-Path $CacheRoot "venv-$key"
    if (Test-PublisherPythonEnvironment -Root $final -Key $key -ImportCheck $ImportCheck) {
        Write-Host "Reusing verified publisher environment $final"
        return (Join-Path $final 'Scripts/python.exe')
    }

    # Staging folders of cancelled jobs are removed once they are a day old; a running job never takes that long.
    Get-ChildItem -LiteralPath $CacheRoot -Directory -Filter 'staging-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-1) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $staging = Join-Path $CacheRoot ("staging-$key-" + [guid]::NewGuid().ToString('N'))
    Write-Host "Creating publisher environment for $($identity[0])"
    & $PythonBin -m venv $staging | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Publisher virtual environment creation failed (exit $LASTEXITCODE)." }
    $stagingPython = Join-Path $staging 'Scripts/python.exe'
    if (-not (Test-Path -LiteralPath $stagingPython -PathType Leaf)) { throw 'Publisher virtual environment has no Python executable.' }
    & $stagingPython -m pip --isolated install --disable-pip-version-check --no-input --prefer-binary -r $RequirementsPath | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Publisher dependency installation failed (exit $LASTEXITCODE)." }
    Set-Content -LiteralPath (Join-Path $staging 'eternet-publisher-ready.txt') -Value $key -Encoding ascii
    if (-not (Test-PublisherPythonEnvironment -Root $staging -Key $key -ImportCheck $ImportCheck)) { throw 'Publisher dependencies are not importable from the new environment.' }

    if (Test-Path -LiteralPath $final) {
        # A broken environment cannot be replaced while another job may be using it; this job keeps its own copy.
        if (Test-PublisherPythonEnvironment -Root $final -Key $key -ImportCheck $ImportCheck) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            return (Join-Path $final 'Scripts/python.exe')
        }
        Write-Host "Cached environment $final is not usable; using this job's environment $staging"
        return $stagingPython
    }
    try {
        [IO.Directory]::Move($staging, $final)
    } catch {
        if (Test-PublisherPythonEnvironment -Root $final -Key $key -ImportCheck $ImportCheck) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            return (Join-Path $final 'Scripts/python.exe')
        }
        return $stagingPython
    }
    $python = Join-Path $final 'Scripts/python.exe'
    if (-not (Test-PublisherPythonEnvironment -Root $final -Key $key -ImportCheck $ImportCheck)) { throw 'Published publisher environment failed verification.' }
    return $python
}
