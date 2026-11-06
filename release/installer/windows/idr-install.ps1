<#
IDR component installer (Windows). Run by IDR-Setup.exe; also usable on its own:

  idr-install.ps1 -Mode Install -Components target-cli,target-gui [-Channel staging] [-InstallDir DIR]
  idr-install.ps1 -Mode Resolve ...   # writes the download plan (IDR-Setup then downloads it)
  idr-install.ps1 -Mode Apply ...     # installs downloaded packages, removes deselected ones
  idr-install.ps1 -Mode Uninstall -InstallDir DIR

Every component goes into one folder (default %LOCALAPPDATA%\Programs\IDR): the
apps find target-agent, source-agent and idr_c_api next to their own exe, so
the shared target-agent is installed once. Signed-in state, keys and device
identities live in %APPDATA% (idr.to-t, idr.to-s) and are never touched here.
#>
param(
  [ValidateSet('Install', 'Resolve', 'Apply', 'Uninstall')] [string]$Mode = 'Install',
  [string]$Channel = 'staging',
  [string[]]$Components = @(),
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\IDR'),
  [string]$BaseUrl = $(if ($env:IDR_RELEASE_BASE) { $env:IDR_RELEASE_BASE } else { 'https://billing.idr.to' }),
  [string]$WorkDir = (Join-Path $env:TEMP 'idr-setup'),
  [string]$ErrorFile = '',
  [switch]$NoPath   # leave the user PATH alone (portable installs, tests)
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Release signing key (public). Matches release/release-key.pem.
$PublicKeyXml = '<RSAKeyValue><Modulus>4Yy2x9ljBck0G+nvld2eVCGLqJZwTvR9viywESRfY6jLkd3XpnyBEnvl6f9/1jQFrw4ZNpC9TRQpngpBFkbHIizEJUfqtSu2DYknHwUc1G0F37plxKowgpCQGfxui4YJsiQgsaQAEA2lXxEUXtzn8m84LwEyr9WqJvYMVFmiUDgKeOAOChpcs0R9r1gRiQyklWfCGO5Vwt3RtzjKD7qN0nmsLqFpq+KWZuUMYRMFhux4HwHhvegvT0c4H9yvxbfFyZtIQ6sIAWUPsWr10DqGUS9m2mUgf/2rqkCXDCOtDE6xfcWOc4f0SjPYUKDe90hmaNC0/p5ca8fRbKyG8Vdywkvl2RtYp6GU3oA8EBk6gHQu9+Vk7JVbJW+81rXZb79D6A6sw+TikwZDvVhrwOo+WRt/Po13UFMDUl9VCxr1TihVu+bB/nzWi0SYyuaEwnR80T2xaonxp/nMjvcO36ZTdBbWx/zi8txSBeuJd6791FfT/aZ/zTGzI3E62xMcVbPD</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
$Platform = 'windows-x64'
$StateDir = Join-Path $InstallDir '.idr'
$PlanFile = Join-Path $WorkDir 'plan.tsv'
$ChannelUrl = "$($BaseUrl.TrimEnd('/'))/$Channel/"
# Inno passes "a,b" as one string.
$Components = @($Components | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Fail([string]$msg) {
  if ($ErrorFile) { [IO.File]::WriteAllText($ErrorFile, $msg) }
  Write-Error $msg -ErrorAction Continue
  exit 1
}

function Get-Bytes([string]$url) {
  $wc = New-Object Net.WebClient
  try { return $wc.DownloadData($url) } finally { $wc.Dispose() }
}

function Get-Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLowerInvariant() }

# Signed manifest: retried once because the .json and .sig are swapped as two renames.
function Get-Manifest {
  for ($try = 1; ; $try++) {
    $json = Get-Bytes "${ChannelUrl}manifest.json"
    $sig = Get-Bytes "${ChannelUrl}manifest.json.sig"
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($PublicKeyXml)
    if ($rsa.VerifyData($json, 'SHA256', $sig)) { break }
    if ($try -ge 2) { Fail 'The release manifest signature is invalid. Nothing was installed.' }
    Start-Sleep -Seconds 3
  }
  $m = [Text.Encoding]::UTF8.GetString($json) | ConvertFrom-Json
  if ($m.channel -ne $Channel) { Fail "Manifest is for channel '$($m.channel)', expected '$Channel'." }
  return $m
}

# Selected components plus everything they require, shared ones once.
function Get-Closure($m, [string[]]$ids) {
  $byId = @{}; foreach ($c in $m.components) { $byId[$c.id] = $c }
  $out = New-Object Collections.Generic.List[string]
  $todo = New-Object Collections.Generic.Queue[string]
  foreach ($i in $ids) { $todo.Enqueue($i) }
  while ($todo.Count) {
    $id = $todo.Dequeue()
    if ($out.Contains($id)) { continue }
    $c = $byId[$id]
    if (-not $c) { Fail "Unknown component '$id'." }
    if (-not $c.files.$Platform) { Fail "$($c.name) is not available for Windows." }
    $out.Add($id)
    foreach ($r in $c.requires) { $todo.Enqueue($r) }
  }
  return , $out.ToArray()
}

function Get-Installed {
  $h = @{}
  if (Test-Path $StateDir) {
    Get-ChildItem $StateDir -Filter '*.sha256' | ForEach-Object { $h[$_.BaseName] = (Get-Content $_.FullName -Raw).Trim() }
  }
  return $h
}

# Files in use cannot be replaced; ask the user to stop them instead of half-installing.
function Assert-NotRunning {
  # Exactly the condition that breaks an update: a program or library that cannot be opened for writing.
  if (-not (Test-Path $InstallDir)) { return }
  $busy = Get-ChildItem $InstallDir -Recurse -File -Include *.exe, *.dll -ErrorAction SilentlyContinue | Where-Object {
    try { [IO.File]::Open($_.FullName, 'Open', 'ReadWrite', 'None').Dispose(); $false } catch { $true }
  } | ForEach-Object { $_.Name }
  if ($busy) { Fail ("These IDR programs are running from $InstallDir`: $($busy -join ', '). " +
      'Stop them (idrt stop, or quit the Target app) and run setup again.') }
}

function Resolve-Plan {
  if (-not $Components.Count) { Fail 'Select at least one component.' }
  Assert-NotRunning
  $m = Get-Manifest
  $want = Get-Closure $m $Components
  $installed = Get-Installed
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  $lines = @("version`t$($m.version)")
  foreach ($c in $m.components) {
    if ($want -notcontains $c.id) { continue }
    $f = $c.files.$Platform
    if ($installed[$c.id] -eq $f.sha256) { $lines += "keep`t$($c.id)"; continue }
    $lines += "get`t$($c.id)`t$ChannelUrl$($f.path)`t$($c.id)-$Platform.zip`t$($f.sha256)"
  }
  Set-Content -Path $PlanFile -Value $lines -Encoding ASCII
  return $lines
}

function Read-Plan { Get-Content $PlanFile | ForEach-Object { , ($_ -split "`t") } }

function Save-Downloads {
  foreach ($p in Read-Plan) {
    if ($p[0] -ne 'get') { continue }
    Write-Host "Downloading $($p[1])..."
    $wc = New-Object Net.WebClient
    try { $wc.DownloadFile($p[2], (Join-Path $WorkDir $p[3])) } finally { $wc.Dispose() }
  }
}

function Set-UserPath([bool]$present) {
  if ($NoPath) { return }
  $dir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @(if ($cur) { $cur -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $dir } })
  if ($present) { $parts += $dir }
  $new = $parts -join ';'
  if ($new -ne $cur) { [Environment]::SetEnvironmentVariable('Path', $new, 'User') }
}

function Install-Plan {
  $plan = @(Read-Plan)
  $version = (Get-Content $PlanFile | Where-Object { $_ -like "version`t*" }) -replace "^version`t", ''
  $want = @($plan | Where-Object { $_[0] -in 'get', 'keep' } | ForEach-Object { $_[1] })
  # Verify every download before touching the install folder.
  foreach ($p in $plan | Where-Object { $_[0] -eq 'get' }) {
    $zip = Join-Path $WorkDir $p[3]
    if (-not (Test-Path $zip) -or (Get-Sha256 $zip) -ne $p[4]) { Fail "Checksum mismatch for $($p[1]). Nothing was changed." }
  }
  Assert-NotRunning
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  foreach ($p in $plan | Where-Object { $_[0] -eq 'get' }) {
    $id = $p[1]
    $tmp = Join-Path $WorkDir "x-$id"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Path (Join-Path $WorkDir $p[3]) -DestinationPath $tmp -Force
    $rels = @(Get-ChildItem $tmp -Recurse -File | ForEach-Object { $_.FullName.Substring($tmp.Length + 1) })
    $oldList = Join-Path $StateDir "$id.files"
    $old = @(if (Test-Path $oldList) { Get-Content $oldList })
    foreach ($r in $rels) {
      $dest = Join-Path $InstallDir $r
      New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
      Copy-Item -Force -Path (Join-Path $tmp $r) -Destination $dest
    }
    Set-Content -Path $oldList -Value $rels -Encoding UTF8
    Set-Content -Path (Join-Path $StateDir "$id.sha256") -Value $p[4] -Encoding ASCII
    Remove-OrphanFiles ($old | Where-Object { $rels -notcontains $_ })
    Remove-Item -Recurse -Force $tmp
    Write-Host "Installed $id"
  }
  # Components no longer selected (or no longer required): remove their files
  # unless a remaining component ships the same file.
  foreach ($id in (Get-Installed).Keys) {
    if ($want -contains $id) { continue }
    $list = Join-Path $StateDir "$id.files"
    $files = @(if (Test-Path $list) { Get-Content $list })
    Remove-Item -Force $list, (Join-Path $StateDir "$id.sha256") -ErrorAction SilentlyContinue
    Remove-OrphanFiles $files
    Write-Host "Removed $id"
  }
  Set-Content -Path (Join-Path $StateDir 'version') -Value $version -Encoding ASCII
  Set-UserPath (($want -contains 'target-cli') -or ($want -contains 'source-cli'))
}

function Remove-OrphanFiles([string[]]$rels) {
  if (-not $rels) { return }
  $kept = @{}
  Get-ChildItem $StateDir -Filter '*.files' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName } | ForEach-Object { $kept[$_] = 1 }
  foreach ($r in $rels) {
    if ($kept.ContainsKey($r)) { continue }
    $f = Join-Path $InstallDir $r
    if (Test-Path $f) { Remove-Item -Force $f }
    # Drop folders the removed files leave empty.
    $d = Split-Path $f
    while ($d.Length -gt $InstallDir.Length -and (Test-Path $d) -and -not (Get-ChildItem $d -Force)) {
      Remove-Item $d; $d = Split-Path $d
    }
  }
}

try {
  switch ($Mode) {
    'Resolve' { Resolve-Plan | Out-Null }
    'Apply' { Install-Plan }
    'Install' { Resolve-Plan | Out-Null; Save-Downloads; Install-Plan; Write-Host "IDR is installed in $InstallDir. Open a new terminal to use idrt / idr." }
    'Uninstall' { Set-UserPath $false; if (Test-Path $StateDir) { Remove-Item -Recurse -Force $StateDir } }
  }
} catch {
  Fail $_.Exception.Message
}
