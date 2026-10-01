param([string]$Godot = 'D:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

function Check-TestLog([string]$Log, [string]$Expected) {
    $lines = Get-Content -LiteralPath $Log
    # This sandbox's Windows certificate store is unavailable to Godot.
    # That startup message is unrelated to these local gameplay/network tests.
    $errors = $lines | Where-Object { $_ -match '^(SCRIPT ERROR|ERROR:)' -and $_ -notmatch 'Failed to read the root certificate store' }
    if ($errors) { throw ($errors -join [Environment]::NewLine) }
    if (-not ($lines | Select-String -SimpleMatch $Expected)) { throw "Missing success marker in $Log" }
}

foreach ($name in @('combat', 'network', 'wall_buy')) {
    $log = Join-Path $PSScriptRoot "$name.log"
    $arguments = @('--headless', '--path', ('"' + $projectRoot + '"'), '--log-file', ('"' + $log + '"'), '--script', "res://tests/${name}_test.gd")
    $testProcess = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (-not $testProcess.WaitForExit(25000)) {
        Stop-Process -Id $testProcess.Id
        throw "$name timed out"
    }
    if ($testProcess.ExitCode -ne 0) { throw "$name failed with exit code $($testProcess.ExitCode)" }
    Check-TestLog $log '0 failures.'
    Get-Content -LiteralPath $log | Select-String 'tests:'
}

$commonArgs = @('--headless', '--path', ('"' + $projectRoot + '"'), '--script', 'res://tests/spawning_smoke_test.gd')
$runningTests = @()
try {
    foreach ($role in @('host', 'early', 'late')) {
        $log = Join-Path $PSScriptRoot "spawn_$role.log"
        $networkArg = if ($role -eq 'host') { '--host' } else { '--join=127.0.0.1' }
        $arguments = $commonArgs + @('--log-file', ('"' + $log + '"'), '--', $networkArg, '--port=24874', "--smoke-role=$role")
        $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $runningTests += [pscustomobject]@{ Process = $process; Role = $role; Log = $log }
        if ($role -eq 'host') { Start-Sleep -Milliseconds 700 }
        if ($role -eq 'early') { Start-Sleep -Milliseconds 1500 }
    }
    foreach ($test in $runningTests) {
        if (-not $test.Process.WaitForExit(25000)) { throw "Spawning $($test.Role) timed out" }
        if ($test.Process.ExitCode -ne 0) { throw "Spawning $($test.Role) failed" }
        Check-TestLog $test.Log "PASS spawning $($test.Role)"
        Write-Output "PASS spawning $($test.Role)"
    }
} finally {
    # These are only the processes launched by this test runner.
    foreach ($test in $runningTests) {
        if (-not $test.Process.HasExited) { Stop-Process -Id $test.Process.Id }
    }
}

$lobbyArgs = @('--headless', '--path', ('"' + $projectRoot + '"'), '--script', 'res://tests/lobby_smoke_test.gd')
$lobbyTests = @()
try {
    foreach ($role in @('host', 'first', 'second')) {
        $log = Join-Path $PSScriptRoot "lobby_$role.log"
        $arguments = $lobbyArgs + @('--log-file', ('"' + $log + '"'), '--', "--lobby-role=$role")
        $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $lobbyTests += [pscustomobject]@{ Process = $process; Role = $role; Log = $log }
        if ($role -eq 'host') { Start-Sleep -Milliseconds 700 }
    }
    foreach ($test in $lobbyTests) {
        if (-not $test.Process.WaitForExit(30000)) { throw "Lobby $($test.Role) timed out" }
        if ($test.Process.ExitCode -ne 0) { throw "Lobby $($test.Role) failed" }
        Check-TestLog $test.Log "PASS lobby $($test.Role)"
        Write-Output "PASS lobby $($test.Role)"
    }
} finally {
    foreach ($test in $lobbyTests) {
        if (-not $test.Process.HasExited) { Stop-Process -Id $test.Process.Id }
    }
}
Write-Output 'All FPS regression checks passed.'

