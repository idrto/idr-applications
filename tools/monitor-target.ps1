# Finite local monitor; does not start, stop, or reconfigure the agent.
param(
    [ValidateRange(2, 3600)][int]$Samples = 30,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 1,
    [string]$PidFile = "$env:APPDATA/idr.to/target/idr_target/target-agent.pid",
    [string]$OutputPath = './target-monitor.json'
)
$ErrorActionPreference = 'Stop'
$rows = [Collections.Generic.List[object]]::new()
$previous = $null
for ($sample = 0; $sample -lt $Samples; $sample++) {
    $timestamp = [DateTimeOffset]::UtcNow
    $agent = $null
    if (Test-Path -LiteralPath $PidFile) {
        $agentProcessId = 0
        if ([int]::TryParse((Get-Content -LiteralPath $PidFile -Raw).Trim(), [ref]$agentProcessId)) {
            $candidate = Get-Process -Id $agentProcessId -ErrorAction SilentlyContinue
            if ($candidate -and $candidate.ProcessName -eq 'target-agent') { $agent = $candidate }
        }
    }
    $coreCpuPercent = $null
    if ($agent -and $previous -and $previous.pid -eq $agent.Id) {
        $elapsed = ($timestamp - $previous.time).TotalSeconds
        $coreCpuPercent = [Math]::Round(100 * ($agent.CPU - $previous.cpu) / $elapsed, 2)
    }
    $row = [ordered]@{ time = $timestamp.ToString('o'); running = [bool]$agent }
    if ($agent) {
        $row.pid = $agent.Id
        $row.coreCpuPercent = $coreCpuPercent
        $row.workingSetMiB = [Math]::Round($agent.WorkingSet64 / 1MB, 2)
        $row.privateMemoryMiB = [Math]::Round($agent.PrivateMemorySize64 / 1MB, 2)
        $previous = @{ pid = $agent.Id; cpu = $agent.CPU; time = $timestamp }
    } else { $previous = $null }
    $rows.Add([pscustomobject]$row)
    [pscustomobject]$row | ConvertTo-Json -Compress | Write-Host
    if ($sample + 1 -lt $Samples) { Start-Sleep -Seconds $IntervalSeconds }
}
$report = [ordered]@{
    note = 'coreCpuPercent: 100 means one fully busy CPU core; null means no comparable previous sample. Process running does not imply Presence/Relay connected.'
    samples = $rows.ToArray()
}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
