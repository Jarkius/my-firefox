<#
.SYNOPSIS
  Fully automated build of a custom portable Firefox for Windows x64.

.DESCRIPTION
  From a bare Windows 10/11 x64 machine to a ready-to-run portable Firefox:
    1. Checks the machine (64-bit, free disk space).
    2. Installs Git for Windows and MozillaBuild if missing (UAC prompts once each).
    3. Gets this repository if the script was run on its own (e.g. via irm | iex).
    4. Runs build-portable.sh in the MozillaBuild shell: clone Firefox source,
       mach bootstrap, patch source, mach build, mach package, assemble, verify.
    5. Extracts the result to -InstallDir and creates a desktop shortcut.
  The PC is kept awake during the build and everything is logged.
  Safe to re-run: finished steps are reused (source checkout, toolchains, objdir).

.EXAMPLE
  .\build.cmd
.EXAMPLE
  .\build.cmd -Policy devtools -Ref release
.EXAMPLE
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Jarkius/my-firefox/main/build.ps1)))
#>
[CmdletBinding()]
param(
  # all: ignore registry/GPO policies (+ DisableDeveloperTools). devtools: only ignore DisableDeveloperTools.
  [ValidateSet('all', 'devtools')] [string] $Policy = 'all',
  # Firefox branch or tag, e.g. main (Nightly), release, FIREFOX_150_0_RELEASE.
  [string] $Ref = 'main',
  # Firefox source checkout (needs ~40 GB incl. build output). Avoid spaces.
  [string] $SrcDir = 'C:\mozilla-source\firefox',
  # Where the finished portable Firefox is extracted.
  [string] $InstallDir = 'C:\FirefoxPortable',
  # Only produce the ZIP in .\dist; do not extract or create a shortcut.
  [switch] $NoInstall,
  # Fetch -Ref again into an existing source checkout.
  [switch] $Update,
  # Rebuild from scratch.
  [switch] $Clobber,
  # Continue even if the free-space check fails.
  [switch] $Force,
  # Used only when this script runs without the rest of the repo next to it.
  [string] $RepoUrl = 'https://github.com/Jarkius/my-firefox.git',
  [string] $RepoBranch = 'main',
  [string] $RepoDir = 'C:\my-firefox'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$MozillaBuild = 'C:\mozilla-build'
$MinFreeGB = 50

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" }
function Fail($msg) { Write-Host "`nERROR: $msg" -ForegroundColor Red; exit 1 }

function Update-PathFromRegistry {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machine;$user"
}

function Get-File($url, $name) {
  $dest = Join-Path $env:TEMP $name
  Info "Downloading $url"
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
  return $dest
}

function Invoke-Installer($path, $arguments, $what) {
  Info "Installing $what (approve the Windows UAC prompt)..."
  $p = Start-Process -FilePath $path -ArgumentList $arguments -Verb RunAs -Wait -PassThru
  if ($p.ExitCode -ne 0) { Fail "$what installer exited with code $($p.ExitCode)" }
}

# Keep the PC (laptop) from sleeping while this process runs.
Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
'@
function Set-KeepAwake([bool] $on) {
  $ES_CONTINUOUS = [uint32]2147483648; $ES_SYSTEM_REQUIRED = [uint32]1
  if ($on) { [void][Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) }
  else { [void][Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS) }
}

$started = Get-Date

# ---------------------------------------------------------------- 1. checks
Step 'Checking this machine'
if (-not [Environment]::Is64BitOperatingSystem) { Fail 'A 64-bit Windows is required.' }
if ($SrcDir -match '\s') { Fail "-SrcDir must not contain spaces: $SrcDir" }
$drive = (Split-Path -Qualifier $SrcDir).TrimEnd(':')
$freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB)
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Info "Free on ${drive}: $freeGB GB, RAM: $ramGB GB, CPU threads: $([Environment]::ProcessorCount)"
$existingSrc = Test-Path (Join-Path $SrcDir 'mach')
if (-not $existingSrc -and $freeGB -lt $MinFreeGB) {
  if ($Force) { Write-Warning "Only $freeGB GB free; the build needs about $MinFreeGB GB." }
  else { Fail "Only $freeGB GB free on ${drive}:, about $MinFreeGB GB is needed (use -Force to try anyway)." }
}
if ($ramGB -lt 8) { Write-Warning 'Less than 8 GB RAM: the build may fail or be extremely slow.' }
$battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
if ($battery -and $battery.BatteryStatus -eq 1) { Write-Warning 'Running on battery: plug the laptop in, the build takes hours.' }

# ---------------------------------------------------------------- 2. prerequisites
Step 'Git for Windows'
Update-PathFromRegistry
if (Get-Command git -ErrorAction SilentlyContinue) {
  Info "Found: $(git --version)"
} else {
  $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/git-for-windows/git/releases/latest'
  $asset = $rel.assets | Where-Object { $_.name -match '^Git-[\d.]+-64-bit\.exe$' } | Select-Object -First 1
  if (-not $asset) { Fail 'Could not find the Git for Windows installer; install Git manually and re-run.' }
  $exe = Get-File $asset.browser_download_url $asset.name
  Invoke-Installer $exe '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES' 'Git for Windows'
  Update-PathFromRegistry
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'Git installed but not on PATH; open a new window and re-run.' }
  Info "Installed: $(git --version)"
}

Step 'MozillaBuild'
$bash = Join-Path $MozillaBuild 'msys2\usr\bin\bash.exe'
if (Test-Path $bash) {
  Info "Found: $MozillaBuild"
} else {
  $exe = Get-File 'https://ftp.mozilla.org/pub/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe' 'MozillaBuildSetup-Latest.exe'
  Invoke-Installer $exe "/S /D=$MozillaBuild" 'MozillaBuild'
  if (-not (Test-Path $bash)) { Fail "MozillaBuild did not install to $MozillaBuild" }
  Info "Installed to $MozillaBuild"
}

# ---------------------------------------------------------------- 3. this repo
Step 'Build scripts'
$here = $PSScriptRoot
if ($here -and (Test-Path (Join-Path $here 'build-portable.sh'))) {
  $repo = $here
} else {
  $repo = $RepoDir
  if (Test-Path (Join-Path $repo '.git')) {
    git -C $repo pull --ff-only
  } else {
    git clone --branch $RepoBranch $RepoUrl $repo
  }
  if ($LASTEXITCODE -ne 0) { Fail "Could not get $RepoUrl" }
}
Info "Using $repo"
$distDir = Join-Path $repo 'dist'
$logDir = Join-Path $repo 'logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("build-{0:yyyyMMdd-HHmmss}.log" -f $started)

# ---------------------------------------------------------------- 4. build
Step "Building Firefox ($Ref, policy: $Policy). This takes hours; the PC is kept awake."
Info "Log: $log"
$shArgs = @('--policy', $Policy, '--ref', $Ref, '--src', $SrcDir, '--out', $distDir)
if ($Update) { $shArgs += '--update' }
if ($Clobber) { $shArgs += '--clobber' }

# Environment for MozillaBuild's MSYS2 login shell (what start-shell.bat sets up).
$env:MSYSTEM = 'MINGW64'
$env:MOZILLABUILD = "$MozillaBuild\"
$env:MSYS2_PATH_TYPE = 'inherit'   # keep Git for Windows etc. on PATH
$env:CHERE_INVOKING = '1'          # stay in the current directory
$env:FF_REPO = $repo
$env:FF_LOG = $log
$env:FF_ARGS = ($shArgs | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '

$cmd = 'set -o pipefail; cd "$(cygpath -u "$FF_REPO")" && ' +
       'eval "./build-portable.sh $FF_ARGS" 2>&1 | tee -a "$(cygpath -u "$FF_LOG")"'
Set-KeepAwake $true
try {
  & $bash -lc $cmd
  $code = $LASTEXITCODE
} finally {
  Set-KeepAwake $false
}
if ($code -ne 0) { Fail "Build failed (exit $code). See the log: $log" }

$zip = Get-ChildItem $distDir -Filter 'FirefoxPortable-*-win64.zip' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $zip) { Fail "No portable ZIP found in $distDir" }

# ---------------------------------------------------------------- 5. install
if (-not $NoInstall) {
  Step "Installing portable Firefox to $InstallDir"
  $target = Join-Path $InstallDir 'firefox'
  $profileDir = Join-Path $target 'profile'
  $keep = $null
  if (Test-Path $profileDir) {
    # Keep the existing profile (bookmarks, logins) across rebuilds.
    $keep = Join-Path $InstallDir "profile.keep"
    if (Test-Path $keep) { Remove-Item -Recurse -Force $keep }
    Move-Item $profileDir $keep
    Info 'Keeping the existing profile'
  }
  if (Test-Path $target) { Remove-Item -Recurse -Force $target }
  New-Item -ItemType Directory -Force $InstallDir | Out-Null
  Expand-Archive -Path $zip.FullName -DestinationPath $InstallDir -Force
  if ($keep) {
    Remove-Item -Recurse -Force $profileDir -ErrorAction SilentlyContinue
    Move-Item $keep $profileDir
  }

  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Firefox Portable.lnk'
  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  $sc.TargetPath = Join-Path $target 'launch.bat'
  $sc.WorkingDirectory = $target
  $sc.IconLocation = (Join-Path $target 'firefox.exe') + ',0'
  $sc.WindowStyle = 7   # minimized: hides the launcher console
  $sc.Save()
  Info "Desktop shortcut: $lnk"
}

$elapsed = (Get-Date) - $started
Step ('Done in {0}h {1}m' -f [int][math]::Floor($elapsed.TotalHours), $elapsed.Minutes)
Info "Portable ZIP: $($zip.FullName)"
if (-not $NoInstall) {
  Info "Installed:    $(Join-Path $InstallDir 'firefox')"
  Info 'Start it with the "Firefox Portable" shortcut on the desktop.'
}
