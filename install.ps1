<#
.SYNOPSIS
  Install and start Vanika on Windows, then open it in your browser.

.DESCRIPTION
  One command from a clean machine to a running stack:

      irm https://raw.githubusercontent.com/<org>/VanikaAi/V2/install.ps1 | iex

  or, from a clone:

      powershell -ExecutionPolicy Bypass -File .\install.ps1

  It checks what is already there, installs only what is missing, tunes WSL2 so
  the virtual machine does not hoard memory, generates the secrets it needs,
  waits for every service to answer, and opens the browser.

  Re-running it is safe. It is the same script used to update: nothing is
  reinstalled that is already correct, and your .env.docker is never overwritten.

.PARAMETER SkipWslTune
  Leave %USERPROFILE%\.wslconfig alone. Use this if you have tuned WSL yourself.

.PARAMETER NoBrowser
  Do not open a browser at the end. Useful on a server or in CI.

.PARAMETER Repair
  Diagnose a stack that is already installed and fix what it can: restart
  unhealthy containers, re-run migrations, reclaim disk.
#>
[CmdletBinding()]
param(
  [switch]$SkipWslTune,
  [switch]$NoBrowser,
  [switch]$Repair
)

$ErrorActionPreference = 'Stop'
$RepoUrl = 'https://github.com/adityapuppala1/VanikaAi.git'
$Branch = 'V2'
$AppUrl = 'http://localhost:8080'
$GatewayHealth = 'http://localhost:3001/v1/health'

# ---------------------------------------------------------------- output ----
function Say([string]$m) { Write-Host "  $m" -ForegroundColor Gray }
function Step([string]$m) { Write-Host "`n> $m" -ForegroundColor Cyan }
function Good([string]$m) { Write-Host "  ok  $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  !   $m" -ForegroundColor Yellow }
function Die([string]$m) { Write-Host "`nx  $m" -ForegroundColor Red; exit 1 }

function Have([string]$cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

# ------------------------------------------------------------ preflight ----
Step 'Checking this machine'

if ($PSVersionTable.PSVersion.Major -lt 5) { Die 'PowerShell 5 or newer is required.' }

$is64 = [Environment]::Is64BitOperatingSystem
if (-not $is64) { Die 'Vanika needs 64-bit Windows.' }

$os = Get-CimInstance Win32_OperatingSystem
$ramGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
Say "Windows $($os.Version), $ramGb GB RAM"
if ($ramGb -lt 8) {
  Warn "8 GB or more is recommended; this machine has $ramGb GB. It will run, but builds will be slow."
}

$freeGb = [math]::Round((Get-PSDrive -Name ($env:SystemDrive[0])).Free / 1GB, 1)
Say "$freeGb GB free on $($env:SystemDrive)"
if ($freeGb -lt 20) { Warn "Docker images need roughly 20 GB. You have $freeGb GB free." }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ------------------------------------------------------------ winget -------
function Install-Package([string]$id, [string]$friendly, [string]$probe) {
  if (Have $probe) { Good "$friendly is already installed"; return $true }
  if (-not (Have 'winget')) {
    Warn "$friendly is missing and winget is not available."
    Say  "Install $friendly manually, then run this script again."
    return $false
  }
  Say "Installing $friendly ..."
  winget install --id $id --silent --accept-package-agreements --accept-source-agreements | Out-Null
  # winget does not refresh this session's PATH.
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
  if (Have $probe) { Good "$friendly installed"; return $true }
  Warn "$friendly was installed but is not on PATH yet. Open a new terminal and re-run."
  return $false
}

Step 'Dependencies'
if (-not (Install-Package 'Git.Git' 'Git' 'git')) { Die 'Git is required.' }

# ------------------------------------------------------------ WSL2 ---------
if (-not $SkipWslTune) {
  Step 'Tuning WSL2'
  $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
  $template = Join-Path $PSScriptRoot 'deploy\wsl\.wslconfig.template'

  # Size the ceiling to the machine rather than shipping one number for everyone.
  $wslMem = if ($ramGb -ge 32) { '12GB' } elseif ($ramGb -ge 16) { '8GB' } else { '5GB' }
  $wslCpu = if ($ramGb -ge 32) { 12 } elseif ($ramGb -ge 16) { 8 } else { 4 }

  if (Test-Path $wslConfig) {
    $existing = Get-Content $wslConfig -Raw
    if ($existing -match 'autoMemoryReclaim') {
      Good 'WSL is already tuned (autoMemoryReclaim is set)'
    } else {
      Copy-Item $wslConfig "$wslConfig.backup" -Force
      Warn "Backed up your .wslconfig to .wslconfig.backup"
      $existing = $null
    }
  }
  if (-not (Test-Path $wslConfig) -or $null -eq $existing) {
    if (Test-Path $template) {
      (Get-Content $template -Raw) -replace 'memory=8GB', "memory=$wslMem" -replace 'processors=8', "processors=$wslCpu" |
        Set-Content $wslConfig -Encoding UTF8
    } else {
      @"
[wsl2]
memory=$wslMem
processors=$wslCpu
swap=2GB
autoMemoryReclaim=gradual
sparseVhd=true
"@ | Set-Content $wslConfig -Encoding UTF8
    }
    Good "Wrote $wslConfig (memory=$wslMem, processors=$wslCpu)"
    Say  'Without this, WSL2 grows to hold Linux page cache and never returns it to Windows,'
    Say  'which is why VmmemWSL can show many gigabytes while the containers use under one.'
    $script:WslNeedsRestart = $true
  }
}

# ------------------------------------------------------------ Docker -------
Step 'Docker'
if (-not (Have 'docker')) {
  if (-not (Install-Package 'Docker.DockerDesktop' 'Docker Desktop' 'docker')) {
    Die 'Docker Desktop is required. Install it from https://docs.docker.com/desktop/install/windows-install/ and re-run.'
  }
  Warn 'Docker Desktop was just installed. Start it once, finish its setup, then re-run this script.'
  exit 0
}

# Wait for the engine: Docker Desktop takes a while after a cold start.
$deadline = (Get-Date).AddMinutes(3)
$engineUp = $false
while ((Get-Date) -lt $deadline) {
  try { docker info 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { $engineUp = $true; break } } catch {}
  Say 'Waiting for the Docker engine ...'
  Start-Sleep -Seconds 5
}
if (-not $engineUp) { Die 'The Docker engine did not come up. Start Docker Desktop and re-run.' }
Good "Docker $((docker version --format '{{.Server.Version}}') 2>$null)"

# ------------------------------------------------------------ source -------
Step 'Source'
$root = $PSScriptRoot
if (-not (Test-Path (Join-Path $root 'docker-compose.yml'))) {
  $root = Join-Path (Get-Location) 'VanikaAi'
  if (Test-Path (Join-Path $root '.git')) {
    Say 'Updating the existing clone ...'
    git -C $root fetch --quiet origin $Branch
    git -C $root checkout --quiet $Branch
    git -C $root pull --quiet --ff-only origin $Branch
  } else {
    Say "Cloning into $root ..."
    git clone --quiet --branch $Branch $RepoUrl $root
  }
}
Set-Location $root
Good "Using $root"

# ------------------------------------------------------------ secrets -----
Step 'Configuration'
$envFile = Join-Path $root '.env.docker'
if (Test-Path $envFile) {
  Good '.env.docker already exists and was left untouched'
} else {
  $example = Join-Path $root '.env.docker.example'
  if (-not (Test-Path $example)) { Die 'No .env.docker.example to work from.' }

  function New-Secret([int]$bytes = 32) {
    $b = New-Object byte[] $bytes
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    [Convert]::ToBase64String($b).TrimEnd('=').Replace('/', '_').Replace('+', '-')
  }

  (Get-Content $example) | ForEach-Object {
    if ($_ -match '^(INTERNAL_API_KEY|PROVIDER_ENCRYPTION_KEY|APP_DB_PASSWORD)=') {
      "$($Matches[1])=$(New-Secret)"
    } else { $_ }
  } | Set-Content $envFile -Encoding UTF8

  # Anything the example does not carry yet is appended, so an older template
  # still produces a complete configuration.
  $content = Get-Content $envFile -Raw
  foreach ($key in @('INTERNAL_API_KEY', 'PROVIDER_ENCRYPTION_KEY', 'APP_DB_PASSWORD')) {
    if ($content -notmatch "(?m)^$key=") { Add-Content $envFile "$key=$(New-Secret)" }
  }
  if ($content -notmatch '(?m)^PUBLIC_APP_URL=') { Add-Content $envFile "PUBLIC_APP_URL=$AppUrl" }

  Good 'Created .env.docker with freshly generated secrets'
  Warn 'Add your Supabase URL and keys to .env.docker before signing in.'
  Say  'Everything else already has a working default.'
}

# ------------------------------------------------------------ repair ------
if ($Repair) {
  Step 'Repairing'
  Say 'Reclaiming build cache ...'
  docker builder prune -af | Select-Object -Last 1
  Say 'Restarting anything unhealthy ...'
  docker compose ps --format '{{.Service}} {{.Status}}' | ForEach-Object {
    if ($_ -notmatch 'Up') { $svc = ($_ -split ' ')[0]; Say "restarting $svc"; docker compose restart $svc | Out-Null }
  }
}


# ------------------------------------------------------ one only ----------
# Refuse to stand up a second copy. Three ways a duplicate happens: two
# installers at once, a second checkout, or something else already holding a
# port. Compose pins the project name so a second checkout replaces these
# containers rather than racing them; the rest is checked here.
Step 'Making sure only one Vanika runs'

$lockPath = Join-Path $env:TEMP 'vanika-install.lock'
try {
  # Opened for the life of this process and released when it exits, including
  # on Ctrl-C, so a cancelled install leaves no stale lock.
  $script:InstallLock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
  Die "Another Vanika install is already running (lock: $lockPath).`n   Wait for it to finish, or delete that file if you are certain it is stale."
}

$running = @(docker ps --filter 'label=com.docker.compose.project=vanikaai' --format '{{.Names}}' 2>$null)
if ($running.Count -gt 0) {
  Say "$($running.Count) service(s) of project 'vanikaai' are already running."
  $where = (docker ps --filter 'label=com.docker.compose.project=vanikaai' --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>$null | Select-Object -First 1)
  if ($where -and ($where.TrimEnd('') -ine $root.TrimEnd(''))) {
    Warn "They were started from: $where"
    Warn "You are in:             $root"
    Say  'Continuing REPLACES those containers rather than starting a second set.'
  }
}

# A port held by something that is not ours would leave a container restarting
# forever with "address already in use"; name the holder instead.
$blocked = @()
foreach ($port in 8080, 3001, 3002, 3003, 3004, 5432, 7447) {
  $mine = docker ps --filter 'label=com.docker.compose.project=vanikaai' --format '{{.Ports}}' 2>$null |
          Select-String -SimpleMatch ":$port->"
  if ($mine) { continue }
  $other = docker ps --format '{{.Names}}	{{.Ports}}' 2>$null | Select-String -SimpleMatch ":$port->"
  if ($other) { $blocked += "port $port is held by container $(($other -split "`t")[0])"; continue }
  $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($listener) {
    $proc = (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    $blocked += "port $port is held by $proc (pid $($listener.OwningProcess))"
  }
}
if ($blocked.Count -gt 0) {
  foreach ($b in $blocked) { Warn $b }
  Die "Free those ports, or stop the other stack, then run this again."
}
Good 'no conflicting stack or port'

# ------------------------------------------------------------ start -------
Step 'Starting Vanika'
Say 'The first run builds images and takes several minutes.'
docker compose up -d --build
if ($LASTEXITCODE -ne 0) { Die 'The stack did not start. Run `docker compose logs` to see why.' }

# ------------------------------------------------------------ wait --------
Step 'Waiting for the services'
$deadline = (Get-Date).AddMinutes(5)
$ready = $false
while ((Get-Date) -lt $deadline) {
  try {
    $g = Invoke-WebRequest -Uri $GatewayHealth -UseBasicParsing -TimeoutSec 5
    $f = Invoke-WebRequest -Uri $AppUrl -UseBasicParsing -TimeoutSec 5
    if ($g.StatusCode -eq 200 -and $f.StatusCode -eq 200) { $ready = $true; break }
  } catch { }
  Say 'not ready yet ...'
  Start-Sleep -Seconds 5
}

# A container that is Up but unreachable from the host almost always means stale
# port forwarding, which is exactly what `wsl --shutdown` leaves behind: Docker
# still reports the ports as published and the service answers inside the
# network, but nothing forwards from the host. Recreating re-establishes it.
if (-not $ready) {
  $anyUp = (docker compose ps --format '{{.Status}}' 2>$null) -match '^Up'
  if ($anyUp) {
    Warn 'Services are running but not answering; re-establishing port publishing ...'
    docker compose up -d --force-recreate 2>&1 | Out-Null
    Start-Sleep -Seconds 20
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
      try {
        $g = Invoke-WebRequest -Uri $GatewayHealth -UseBasicParsing -TimeoutSec 5
        $f = Invoke-WebRequest -Uri $AppUrl -UseBasicParsing -TimeoutSec 5
        if ($g.StatusCode -eq 200 -and $f.StatusCode -eq 200) { $ready = $true; Good 'recovered after re-publishing the ports'; break }
      } catch { }
      Start-Sleep -Seconds 5
    }
  }
}

if (-not $ready) {
  Warn 'The services did not answer in time.'
  Say  'docker compose ps          - what is running'
  Say  'docker compose logs -f     - why something is not'
  Say  ".\install.ps1 -Repair     - try to fix it automatically"
  exit 1
}
Good 'Gateway and web app are answering'

# ------------------------------------------------------------ done -------
Write-Host ''
Write-Host '  Vanika is running.' -ForegroundColor Green
Write-Host "  $AppUrl" -ForegroundColor White
if ($script:WslNeedsRestart) {
  Write-Host ''
  Warn 'One more step to free the memory WSL is holding:'
  Say  'wsl --shutdown        then start Docker Desktop again'
  Say  'This applies the memory ceiling and lets WSL hand cache back to Windows.'
}
Write-Host ''
Say 'docker compose logs -f    follow the logs'
Say 'docker compose down       stop everything'
Say '.\install.ps1 -Repair     diagnose and fix'

if (-not $NoBrowser) { Start-Process $AppUrl }
