$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$bash = Get-Command bash.exe -ErrorAction SilentlyContinue
if ($null -eq $bash) {
    $bash = Get-Command bash -ErrorAction SilentlyContinue
}

if ($null -eq $bash) {
    Write-Error "A Bash executable is required. Install Git for Windows or enable WSL, then run launch.ps1 again."
    exit 1
}

& $bash.Source (Join-Path $scriptDir "launch.sh") @args
exit $LASTEXITCODE
