# Read Free: install it on Windows, and keep it up to date. website/install.sh does the same on
# macOS and Linux (docs/auto-update.md).
#
# In PowerShell, in a normal window:
#   irm https://readfree.xyz/install.ps1 -OutFile install.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#
#   install.ps1                      download the newest release, check its signature, unpack it
#                                    into the Read Free folder, and check for updates every hour
#   install.ps1 install no-schedule  install without the hourly check
#   install.ps1 update               check for an update now
#   install.ps1 status               the folder, the version, the hourly check, the last log lines
#   install.ps1 uninstall            stop checking for updates (the folder stays until you delete it)
#
# Then, once, in Chrome (or Edge, Brave, Vivaldi, Dia): chrome://extensions, Developer mode on, and
# the folder this shows dropped onto that page (or Load unpacked). Leave Developer mode on: with it
# off, Chrome turns unpacked extensions off when they reload, and Read Free reloads itself after
# each update.
#
# Every release is signed. This script holds the project's public key ($SIGNER) and installs only a
# release signed with it (checked by Windows' own OpenSSH: ssh-keygen -Y verify), newer than the one
# installed, whose zip has the signed size and SHA-256. The hourly check, a Task Scheduler task
# called "Read Free updater", runs the copy of this script kept next to the extension, never a fresh
# download, so a site or mirror in the wrong hands can't put code in your browser. Running a newer
# install.ps1 by hand replaces that copy.
# Where things go: %LOCALAPPDATA%\Read Free: the extension, "Read Free updater.ps1", update.log.
# Written for Windows PowerShell 5.1, which every Windows 10 and 11 has. ASCII only: Windows
# PowerShell reads a file without a byte-order mark in the system's code page.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Where releases are published, tried in order: the site, then mirrors. https, ending in /,
# separated by spaces. tools/release.sh writes in website/install.sh's list (RELEASE_URLS there).
$RELEASE_URLS = 'https://readfree.xyz/ https://readfreexyz.github.io/'
# The release key's public half, as an allowed_signers line. tools/release.sh writes in
# website/install.sh's (SIGNER there).
$SIGNER = 'read-free namespaces="read-free-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINYpjAv6OljQ8lBV7Chb0mZHXwxxMKSBS/0FbxiJLCPn'
$NAMESPACE = 'read-free-release'
$PRINCIPAL = 'read-free'
$MAX_ZIP = 52428800
$TASK = 'Read Free updater'

$Base = Join-Path $env:LOCALAPPDATA 'Read Free'
$Ext = Join-Path $Base 'extension'
$Self = Join-Path $Base 'Read Free updater.ps1'
$LogFile = Join-Path $Base 'update.log'
$Lock = Join-Path $Base '.update.lock'

# The command and its options, as words: "no-schedule" and "--no-schedule" alike
$Words = @($args | ForEach-Object { ([string]$_).TrimStart('-').ToLowerInvariant() })
$Command = if ($Words.Count -ge 1) { $Words[0] } else { 'install' }
if ($Command -eq 'no-schedule') { $Command = 'install'; $Words = @('install', 'no-schedule') }
$Options = if ($Words.Count -ge 2) { @($Words[1..($Words.Count - 1)]) } else { @() }
# The hourly task passes "log": then nothing is shown, and updates and failures go to update.log
$Logging = $Options -contains 'log'

$script:Trail = New-Object System.Collections.Generic.List[string]
$script:Keygen = $null
$script:Work = $null
$script:Release = $null
$script:New = $null
$script:Lines = @()
$script:Version = ''
$script:Zip = ''
$script:Sha = ''
$script:Size = ''

# Newer TLS where this .NET doesn't use it by itself (GitHub Pages wants 1.2)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13 } catch { }

function Stamp([string]$Text) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Text" }
# Said only to a person; the hourly task logs updates and failures alone
function Say([string]$Text) { if (-not $Logging) { Write-Host "read-free: $Text" } }
# What went wrong with an address: said at once to a person, logged by the hourly task only if
# the run ends in an update or a failure (a mirror that's down isn't news every hour)
function Note([string]$Text) { if ($Logging) { $script:Trail.Add((Stamp $Text)) } else { Write-Host (Stamp $Text) } }
# An update, or a failure: in update.log for the hourly task (after what led to it)
function Record([string]$Text) {
  if (-not $Logging) { Write-Host (Stamp $Text); return }
  try {
    foreach ($line in $script:Trail) { Add-Content -LiteralPath $LogFile -Value $line -Encoding ASCII }
    Add-Content -LiteralPath $LogFile -Value (Stamp $Text) -Encoding ASCII
  } catch { }
  $script:Trail.Clear()
}
function Die([string]$Text) {
  if ($Logging) { Record $Text } else { Write-Host "read-free: $Text" -ForegroundColor Red }
  exit 1
}
function Q([string]$Text) { '"' + $Text + '"' }

# Runs a program and waits; standard input from a file, byte for byte (signatures cover bytes).
# Returns { Code, Out }.
function Native([string]$Exe, [string]$Arguments, [string]$StdIn = '') {
  $tmp = if ($script:Work) { $script:Work } else { [IO.Path]::GetTempPath() }
  $outFile = Join-Path $tmp ('.out.' + [guid]::NewGuid().ToString('N'))
  $errFile = "$outFile.err"
  try {
    $params = @{ FilePath = $Exe; ArgumentList = $Arguments; NoNewWindow = $true; Wait = $true; PassThru = $true; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile }
    if ($StdIn) { $params.RedirectStandardInput = $StdIn }
    $p = Start-Process @params
    $output = ''
    foreach ($f in @($outFile, $errFile)) { if (Test-Path -LiteralPath $f) { $output += [IO.File]::ReadAllText($f) } }
    return @{ Code = $p.ExitCode; Out = $output }
  } catch {
    return @{ Code = -1; Out = $_.Exception.Message }
  } finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

# Windows' OpenSSH client (there by default since Windows 10 1809), new enough for signatures
function Find-Keygen {
  # Windows' own first; else whichever is on the path (Git's, say)
  $path = $null
  $builtIn = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe'
  if (Test-Path -LiteralPath $builtIn) { $path = $builtIn }
  if (-not $path) {
    $found = Get-Command 'ssh-keygen.exe' -ErrorAction SilentlyContinue
    if ($found) { $path = $found.Source }
  }
  if (-not $path) { Die "Windows' OpenSSH client isn't installed (Settings, Apps, Optional features: OpenSSH Client). Or use the zip from the site." }
  # -Y (signatures) came in OpenSSH 8.1: an older one calls it an unknown option
  $probe = Native $path '-Y'
  if ($probe.Out -match 'illegal option|invalid option|unknown option') { Die "this Windows' OpenSSH is too old to check signatures (8.1 or later is needed: update Windows). Or use the zip from the site." }
  return $path
}

function Configured {
  if (-not $RELEASE_URLS) { Die 'this copy has no release address (RELEASE_URLS)' }
  foreach ($address in @($RELEASE_URLS -split '\s+' | Where-Object { $_ })) {
    if ($address -notmatch '^https://\S+/$') { Die "not an https address ending in /: $address" }
  }
  if (-not $SIGNER.StartsWith("$PRINCIPAL namespaces=`"$NAMESPACE`" ssh-ed25519 ")) { Die 'this copy has no signing key (SIGNER)' }
  $script:Keygen = Find-Keygen
}

# https only, redirects included; at most $Max bytes. $true when $Out holds the file.
function Fetch([string]$Url, [string]$Out, [long]$Max) {
  $response = $null
  try {
    $request = [System.Net.WebRequest]::Create($Url)
    if ($request.RequestUri.Scheme -ne 'https') { return $false }
    $request.Timeout = 300000
    $request.ReadWriteTimeout = 300000
    $request.AllowAutoRedirect = $true
    $request.MaximumAutomaticRedirections = 5
    $request.UserAgent = 'Read Free updater'
    $response = $request.GetResponse()
    if ($response.ResponseUri.Scheme -ne 'https' -or [int]$response.StatusCode -ne 200) { return $false }
    if ($response.ContentLength -gt $Max) { return $false }
    $in = $response.GetResponseStream()
    $file = [IO.File]::Create($Out)
    try {
      $buffer = New-Object byte[] 65536
      $total = 0
      while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $total += $n
        if ($total -gt $Max) { return $false }
        $file.Write($buffer, 0, $n)
      }
    } finally {
      $file.Dispose()
      $in.Dispose()
    }
    return $true
  } catch {
    return $false
  } finally {
    if ($response) { $response.Close() }
  }
}

function Field([string]$Name) {
  foreach ($line in $script:Lines) { if ($line.StartsWith("$Name=")) { return $line.Substring($Name.Length + 1) } }
  return ''
}

function Version-In([string]$Manifest) {
  try { return [string](([IO.File]::ReadAllText($Manifest)) | ConvertFrom-Json).version } catch { return '' }
}
function Installed { Version-In (Join-Path $Ext 'manifest.json') }

# $A newer than $B, numerically: 0.14.10 is newer than 0.14.9
function Is-Newer([string]$A, [string]$B) {
  $x = @($A -split '\.')
  $y = @($B -split '\.')
  for ($i = 0; $i -lt [Math]::Max($x.Count, $y.Count); $i++) {
    $p = 0; $q = 0
    if ($i -lt $x.Count -and $x[$i]) { $p = [long]$x[$i] }
    if ($i -lt $y.Count -and $y[$i]) { $q = [long]$y[$i] }
    if ($p -gt $q) { return $true }
    if ($p -lt $q) { return $false }
  }
  return $false
}

# The signed description of the newest release at $Url, checked, into $script:Version, Zip, Sha,
# Size. Nothing in it is read before its signature checks out.
function Describe([string]$Url) {
  if (Test-Path -LiteralPath $script:Release) { Remove-Item -LiteralPath $script:Release -Recurse -Force }
  New-Item -ItemType Directory -Path $script:Release | Out-Null
  $txt = Join-Path $script:Release 'latest.txt'
  $sig = "$txt.sig"
  if (-not (Fetch "${Url}latest.txt" $txt 4096) -or -not (Fetch "${Url}latest.txt.sig" $sig 4096)) { Note "${Url}: no answer"; return $false }
  $signers = Join-Path $script:Release 'allowed_signers'
  [IO.File]::WriteAllText($signers, "$SIGNER`n")
  $check = Native $script:Keygen "-Y verify -f $(Q $signers) -I $PRINCIPAL -n $NAMESPACE -s $(Q $sig)" $txt
  if ($check.Code -ne 0) { Note "${Url}: latest.txt isn't signed with the Read Free key; ignored"; return $false }
  $script:Lines = @([IO.File]::ReadAllText($txt) -split "`n")
  $script:Version = Field 'version'
  $script:Zip = Field 'zip'
  $script:Sha = Field 'sha256'
  $script:Size = Field 'size'
  $known = $script:Lines[0] -ceq 'read-free-release 1' -and $script:Version -cmatch '^[0-9]{1,5}(\.[0-9]{1,5}){0,3}$' `
    -and $script:Zip -ceq "read-free-$($script:Version).zip" -and $script:Sha -cmatch '^[0-9a-f]{64}$' `
    -and $script:Size -cmatch '^[0-9]{1,9}$'
  if (-not $known -or [long]$script:Size -gt $MAX_ZIP) { Note "${Url}: latest.txt isn't a release this script knows; ignored"; return $false }
  return $true
}

# The release described, from $Url: downloaded, checked against the signed size and SHA-256, and
# unpacked into $script:New.
function Unpack([string]$Url) {
  $zipFile = Join-Path $script:Release $script:Zip
  if (-not (Fetch "$Url$($script:Zip)" $zipFile ([long]$script:Size))) { Note "$Url$($script:Zip): no answer"; return $false }
  $hash = (Get-FileHash -LiteralPath $zipFile -Algorithm SHA256).Hash.ToLowerInvariant()
  if ((Get-Item -LiteralPath $zipFile).Length -ne [long]$script:Size -or $hash -cne $script:Sha) { Note "$Url$($script:Zip) isn't the file that was signed; ignored"; return $false }
  if (Test-Path -LiteralPath $script:New) { Remove-Item -LiteralPath $script:New -Recurse -Force }
  try { Expand-Archive -LiteralPath $zipFile -DestinationPath $script:New -Force } catch { Note "$Url$($script:Zip) doesn't hold Read Free $($script:Version); ignored"; return $false }
  if ((Version-In (Join-Path $script:New 'manifest.json')) -cne $script:Version) { Note "$Url$($script:Zip) doesn't hold Read Free $($script:Version); ignored"; return $false }
  return $true
}

function Take-Lock {
  try { New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null; return $true } catch { }
  # One left by a run that was stopped: older than an hour
  $held = Get-Item -LiteralPath $Lock -ErrorAction SilentlyContinue
  if ($held -and $held.LastWriteTime -lt (Get-Date).AddMinutes(-60)) {
    Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue
    try { New-Item -ItemType Directory -Path $Lock -ErrorAction Stop | Out-Null; return $true } catch { }
  }
  return $false
}

# Asks the release addresses in turn; the first signed answer says what the newest release is.
# Installs it if it's newer than the one here. Returns 0, or 1 if nothing answered or it failed.
function Update-ReadFree {
  Configured
  New-Item -ItemType Directory -Force -Path $Base | Out-Null
  if (-not (Take-Lock)) { Say 'another update is running'; return 0 }
  try {
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 200000) {
      $tail = Get-Content -LiteralPath $LogFile -Tail 500
      Set-Content -LiteralPath $LogFile -Value $tail -Encoding ASCII
    }
    # Unpacked next to the extension, so putting it in place is a rename
    $script:Work = Join-Path $Base ('.update.' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:Work | Out-Null
    $script:Release = Join-Path $script:Work 'release'
    $script:New = Join-Path $script:Work 'extension'
    $current = Installed
    foreach ($address in @($RELEASE_URLS -split '\s+' | Where-Object { $_ })) {
      if (-not (Describe $address)) { continue }
      if (-not (Is-Newer $script:Version $current)) { Say "up to date ($current)"; return 0 }
      if (-not (Unpack $address)) { continue }
      if (Test-Path -LiteralPath $Ext) {
        $old = Join-Path $script:Work 'old'
        try { Move-Item -LiteralPath $Ext -Destination $old } catch { Record "couldn't move $Ext aside (is a file in it open?); kept $current"; return 1 }
        try { Move-Item -LiteralPath $script:New -Destination $Ext } catch {
          Move-Item -LiteralPath $old -Destination $Ext
          Record "couldn't put $($script:Version) in place; kept $current"
          return 1
        }
      } else {
        Move-Item -LiteralPath $script:New -Destination $Ext
      }
      $was = if ($current) { $current } else { 'nothing' }
      Record "updated: $was -> $($script:Version) (from $address)"
      return 0
    }
    Record 'no release address gave a signed release'
    return 1
  } finally {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    $script:Work = $null
    Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# The hourly check: a Task Scheduler task for this user, at login and every hour, running the kept
# copy with "update log". Without a window where Windows can (conhost --headless), so none flashes
# up every hour.
function Set-Schedule {
  $powershell = Join-Path $PSHOME 'powershell.exe'
  $taskArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File $(Q $Self) update log"
  $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
  $headless = $false
  # The console host knows --headless from Windows 10 1809 (build 17763) on. It can't be tried from
  # here: started with its output redirected, it never runs its program (it takes those handles
  # for a terminal's), and it exits 0 either way. Under Task Scheduler it does run it (test/windows/).
  if ((Test-Path -LiteralPath $conhost) -and [Environment]::OSVersion.Version.Build -ge 17763) { $headless = $true }
  if ($headless) {
    $action = New-ScheduledTaskAction -Execute $conhost -Argument "--headless $(Q $powershell) $taskArgs"
  } else {
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $taskArgs
  }
  $triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1))
  )
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
  try {
    Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $triggers -Settings $settings -Description 'Read Free: checks for a new signed release every hour and installs it.' -Force | Out-Null
  } catch {
    Die "couldn't set up the hourly check ($($_.Exception.Message)). Read Free is installed; run the updater's update now and then."
  }
  Say "checks for updates at login and every hour (Task Scheduler: $TASK; log: $LogFile)"
}

function Install-ReadFree {
  Configured
  # The hourly check needs this script as a file
  $me = $PSCommandPath
  if (-not $me -or -not (Test-Path -LiteralPath $me) -or -not (Select-String -LiteralPath $me -Pattern '^\$SIGNER = ' -Quiet)) {
    Die 'download this script and run it as a file: irm <the site>install.ps1 -OutFile install.ps1; powershell -ExecutionPolicy Bypass -File .\install.ps1'
  }
  New-Item -ItemType Directory -Force -Path $Base | Out-Null
  $code = Update-ReadFree | Select-Object -Last 1
  if ([int]$code -ne 0) { Die "couldn't install: see the lines above" }
  $copied = $false
  if ([IO.Path]::GetFullPath($me) -ne [IO.Path]::GetFullPath($Self)) {
    Copy-Item -LiteralPath $me -Destination "$Self.tmp" -Force
    Move-Item -LiteralPath "$Self.tmp" -Destination $Self -Force
    $copied = $true
  }
  Unblock-File -LiteralPath $Self -ErrorAction SilentlyContinue
  if ($Options -notcontains 'no-schedule') { Set-Schedule }

  # Explorer, with the folder selected, to drag onto chrome://extensions; its path copied for
  # Load unpacked. Not for "no-window" (tests).
  $shown = $false
  $pasted = $false
  if ($Options -notcontains 'no-window') {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,$(Q $Ext)"; $shown = $true } catch { }
    try { Set-Clipboard -Value $Ext; $pasted = $true } catch { }
  }
  Write-Host ''
  Write-Host "Read Free $(Installed) is in:"
  Write-Host "  $Ext"
  Write-Host ''
  Write-Host 'Once, in Chrome (or Edge, Brave, Vivaldi, Dia):'
  Write-Host '  1. Open chrome://extensions and turn on Developer mode (top right). Leave it on:'
  Write-Host '     with it off, Chrome turns Read Free off when it updates itself.'
  if ($shown) {
    Write-Host '  2. Drag the folder selected in the window that just opened (it''s called "extension")'
    Write-Host '     onto that page.'
    if ($pasted) { Write-Host '     Or click Load unpacked: its path is copied, so paste it into the folder box and press Enter.' }
  } else {
    Write-Host '  2. Click Load unpacked and choose the folder above.'
  }
  Write-Host ''
  Write-Host 'Later, to see how it''s doing, or to stop the updates:'
  Write-Host "  powershell -ExecutionPolicy Bypass -File $(Q $Self) status"
  Write-Host "  powershell -ExecutionPolicy Bypass -File $(Q $Self) uninstall"
  if ($copied) { Write-Host "You can delete $(Split-Path -Leaf $me): Read Free keeps its own copy, called $(Split-Path -Leaf $Self)." }
}

function Show-Status {
  Write-Host "folder: $Ext"
  Write-Host "  version: $(Installed)"
  $job = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
  if ($job) { Write-Host "updates: Task Scheduler task `"$TASK`", $($job.State)" } else { Write-Host 'updates: not scheduled' }
  Write-Host "log: $LogFile"
  if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail 5 | ForEach-Object { Write-Host "  $_" } }
}

function Uninstall-ReadFree {
  $job = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
  if ($job) { Unregister-ScheduledTask -TaskName $TASK -Confirm:$false }
  Say "no longer checks for updates. Remove Read Free in chrome://extensions, then delete $Base"
}

switch ($Command) {
  'install' { Install-ReadFree; exit 0 }
  'update' { $code = Update-ReadFree | Select-Object -Last 1; exit ([int]$code) }
  'status' { Show-Status; exit 0 }
  'uninstall' { Uninstall-ReadFree; exit 0 }
  default { Write-Host 'usage: install.ps1 [install [no-schedule] | update | status | uninstall]'; exit 2 }
}
