<#
  Install Open Source Point of Sale (OSPOS) on Windows 10/11 as a portable, self-contained folder.

  What it sets up (everything inside one folder, default C:\OSPOS):
    php\       PHP 8.3 (official Windows build from windows.php.net)
    mariadb\   MariaDB 10.11 database server (official zip from mariadb.org)
    data\      the database files (your shop data lives here - back this folder up)
    ospos\     the OSPOS app, unpacked from the prebuilt zip in ..\offline
    Start OSPOS.bat / Stop OSPOS.bat and desktop shortcuts

  No XAMPP, no Windows services, no build tools. Admin rights are only needed if the
  Microsoft Visual C++ runtime is missing (Windows will then ask once).

  Offline use:
    The PHP and MariaDB zips are saved in windows\downloads the first time. After that the
    installer needs no internet. To install on a computer that is never online, run
        install.bat -DownloadOnly
    on any Windows PC with internet, then copy this whole folder (with windows\downloads)
    to the offline laptop on a USB stick and run install.bat there.

  Parameters:
    -InstallDir  where to install (default C:\OSPOS)
    -Port        web port (default 8080) -> OSPOS opens at http://localhost:8080
    -DbPort      database port (default 3307, chosen so it does not clash with another MySQL)
    -DownloadOnly  only download the PHP/MariaDB/VC++ packages into windows\downloads
#>
param(
    [string]$InstallDir = 'C:\OSPOS',
    [int]$Port = 8080,
    [int]$DbPort = 3307,
    [switch]$DownloadOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster on PowerShell 5
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$MariaDbVersion = '10.11.14'
$PhpBranch = '8.3'

$ScriptDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ScriptDir
$Cache = Join-Path $ScriptDir 'downloads'
New-Item -ItemType Directory -Force -Path $Cache | Out-Null

function Step($msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host ''; Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

function New-Secret {
    $bytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Save-Download($url, $fileName, $sha256) {
    $target = Join-Path $Cache $fileName
    if (Test-Path $target) { return $target }
    Write-Host "    downloading $url"
    $partial = "$target.part"
    Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing
    if ($sha256) {
        $actual = (Get-FileHash -Algorithm SHA256 -Path $partial).Hash
        if ($actual -ne $sha256.ToUpper()) { Remove-Item -Force $partial; Fail "Checksum mismatch for $fileName - download again." }
    }
    Move-Item -Force $partial $target
    return $target
}

# Runs a command-line program and returns its exit code. Windows PowerShell 5 turns anything a
# program prints on stderr into a script-stopping error, so error handling is relaxed around it.
function Invoke-Program($exe, [string[]]$arguments, [switch]$Quiet) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Quiet) { & $exe @arguments *> $null } else { & $exe @arguments 2>&1 | ForEach-Object { Write-Host "    $_" } }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
}

# ---------------------------------------------------------------- packages
function Get-PhpZip {
    $cached = Get-ChildItem -Path $Cache -Filter "php-$PhpBranch.*-nts-Win32-vs*-x64.zip" -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
    if ($cached) { return $cached.FullName }

    Write-Host "    looking up the latest PHP $PhpBranch release"
    $json = Invoke-RestMethod -Uri 'https://windows.php.net/downloads/releases/releases.json' -UseBasicParsing
    $branch = $json.$PhpBranch
    if (-not $branch) { Fail "PHP $PhpBranch not found on windows.php.net" }
    $build = $branch.PSObject.Properties | Where-Object { $_.Name -match '^nts-vs\d+-x64$' } | Select-Object -First 1
    if (-not $build) { Fail "No 64-bit non-thread-safe PHP $PhpBranch build found on windows.php.net" }
    $fileName = $build.Value.zip.path
    return Save-Download "https://windows.php.net/downloads/releases/$fileName" $fileName $build.Value.zip.sha256
}

function Get-MariaDbZip {
    $fileName = "mariadb-$MariaDbVersion-winx64.zip"
    $url = "https://archive.mariadb.org/mariadb-$MariaDbVersion/winx64-packages/$fileName"
    return Save-Download $url $fileName
}

function Test-VcRuntime {
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($item -and $item.Installed -eq 1 -and $item.Major -ge 14 -and $item.Minor -ge 30) { return $true }
    }
    return $false
}

function Get-VcRedist {
    return Save-Download 'https://aka.ms/vs/17/release/vc_redist.x64.exe' 'vc_redist.x64.exe'
}

Step 'Getting PHP, MariaDB and the Visual C++ runtime (cached in windows\downloads)'
$phpZip = Get-PhpZip
$mariaZip = Get-MariaDbZip
$needVc = -not (Test-VcRuntime)
if ($needVc -or $DownloadOnly) { $vcExe = Get-VcRedist }
Write-Host "    PHP     : $(Split-Path -Leaf $phpZip)"
Write-Host "    MariaDB : $(Split-Path -Leaf $mariaZip)"

if ($DownloadOnly) {
    Step 'Download finished'
    Write-Host "Copy this whole folder (including windows\downloads) to the offline computer and run install.bat there."
    exit 0
}

$ospZip = Get-ChildItem -Path (Join-Path $RepoRoot 'offline') -Filter 'ospos-*-prebuilt.zip' -ErrorAction SilentlyContinue |
    Sort-Object Name | Select-Object -Last 1
if (-not $ospZip) { Fail "No prebuilt OSPOS zip found in $RepoRoot\offline" }

if ($needVc) {
    Step 'Installing the Microsoft Visual C++ runtime (Windows will ask for permission)'
    $p = Start-Process -FilePath $vcExe -ArgumentList '/install', '/quiet', '/norestart' -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010 -and $p.ExitCode -ne 1638) {
        Fail "Visual C++ runtime install failed (exit code $($p.ExitCode))"
    }
}

# ---------------------------------------------------------------- unpack
$PhpDir = Join-Path $InstallDir 'php'
$MariaDir = Join-Path $InstallDir 'mariadb'
$DataDir = Join-Path $InstallDir 'data'
$AppDir = Join-Path $InstallDir 'ospos'

if (Test-Path $AppDir) {
    Fail "$AppDir already exists. OSPOS seems to be installed already - use 'Start OSPOS' instead. To reinstall, stop OSPOS and delete $InstallDir first (this deletes your shop data)."
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
function Expand-To($zip, $dest) {
    # Unzip next to the destination (same drive) so the final move always works.
    $tmp = Join-Path $InstallDir (".unzip-" + [guid]::NewGuid().ToString('N'))
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    $children = @(Get-ChildItem -Path $tmp)
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) { $src = $children[0].FullName } else { $src = $tmp }
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Move-Item -Path $src -Destination $dest
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
}

Step "Unpacking into $InstallDir"
Expand-To $phpZip $PhpDir
Expand-To $mariaZip $MariaDir
Expand-To $ospZip.FullName $AppDir

# ---------------------------------------------------------------- PHP config
Step 'Configuring PHP'
$ini = Get-Content -Path (Join-Path $PhpDir 'php.ini-production')
$wanted = 'curl|fileinfo|gd|intl|mbstring|mysqli|openssl|pdo_mysql|zip|sodium'
$ini = $ini | ForEach-Object { if ($_ -match "^;extension=($wanted)\s*$") { "extension=$($Matches[1])" } else { $_ } }
$ini += ''
$ini += '; --- OSPOS settings ---'
$ini += ('extension_dir = "' + (Join-Path $PhpDir 'ext') + '"')
$ini += 'memory_limit = 256M'
$ini += 'upload_max_filesize = 16M'
$ini += 'post_max_size = 16M'
[IO.File]::WriteAllText((Join-Path $PhpDir 'php.ini'), ($ini -join "`r`n"))

$php = Join-Path $PhpDir 'php.exe'
$modules = & $php -m
$missing = @('bcmath', 'curl', 'gd', 'intl', 'json', 'mbstring', 'mysqli', 'openssl', 'xml') |
    Where-Object { $modules -notcontains $_ }
if ($missing) { Fail ("PHP is missing extensions: " + ($missing -join ', ')) }
Write-Host "    $((& $php -v)[0])"

# ---------------------------------------------------------------- MariaDB
Step 'Setting up the MariaDB database'
$RootPass = New-Secret
$DbPass = New-Secret
$bin = Join-Path $MariaDir 'bin'
$installDb = Join-Path $bin 'mariadb-install-db.exe'
if (-not (Test-Path $installDb)) { $installDb = Join-Path $bin 'mysql_install_db.exe' }
$code = Invoke-Program $installDb @("--datadir=$DataDir", "--password=$RootPass", "--port=$DbPort")
if ($code -ne 0) { Fail 'MariaDB data folder could not be created' }

$mysqld = Join-Path $bin 'mysqld.exe'
if (-not (Test-Path $mysqld)) { $mysqld = Join-Path $bin 'mariadbd.exe' }
$client = Join-Path $bin 'mysql.exe'
if (-not (Test-Path $client)) { $client = Join-Path $bin 'mariadb.exe' }
$myIni = Join-Path $DataDir 'my.ini'

Start-Process -FilePath $mysqld -ArgumentList "--defaults-file=`"$myIni`"" -WindowStyle Hidden
$env:MYSQL_PWD = $RootPass   # lets the mysql client log in without a password on the command line
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1
    if ((Invoke-Program $client @('-u', 'root', '-h', '127.0.0.1', "--port=$DbPort", '-e', 'SELECT 1') -Quiet) -eq 0) { $ready = $true; break }
}
if (-not $ready) { Fail ("MariaDB did not start. Is something else using port ${DbPort}? Try: install.bat -DbPort 3308") }

$sql = "CREATE DATABASE ospos CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; " +
       "CREATE USER 'ospos'@'localhost' IDENTIFIED BY '$DbPass'; " +
       "CREATE USER 'ospos'@'127.0.0.1' IDENTIFIED BY '$DbPass'; " +
       "GRANT ALL ON ospos.* TO 'ospos'@'localhost'; " +
       "GRANT ALL ON ospos.* TO 'ospos'@'127.0.0.1'; FLUSH PRIVILEGES;"
$code = Invoke-Program $client @('-u', 'root', '-h', '127.0.0.1', "--port=$DbPort", '-e', $sql)
Remove-Item Env:\MYSQL_PWD
if ($code -ne 0) { Fail 'Could not create the OSPOS database' }

# ---------------------------------------------------------------- OSPOS config
Step 'Configuring OSPOS'
$hosts = "localhost:$Port,127.0.0.1:$Port"   # OSPOS checks the host name including the port
$envLines = Get-Content -Path (Join-Path $AppDir '.env.example') | ForEach-Object {
    if ($_ -match '^CI_ENVIRONMENT=') { 'CI_ENVIRONMENT=production' }
    elseif ($_ -match '^app\.allowedHostnames=') { "app.allowedHostnames='$hosts'" }
    elseif ($_ -match '^database\.default\.hostname=') { "database.default.hostname='127.0.0.1'"; "database.default.port=$DbPort" }
    elseif ($_ -match '^database\.default\.database=') { "database.default.database='ospos'" }
    elseif ($_ -match '^database\.default\.username=') { "database.default.username='ospos'" }
    elseif ($_ -match '^database\.default\.password=') { "database.default.password='$DbPass'" }
    else { $_ }
}
# Written without a byte-order mark: PowerShell 5's UTF8 encoding adds one, which breaks .env parsing.
[IO.File]::WriteAllText((Join-Path $AppDir '.env'), (($envLines -join "`n") + "`n"))

# ---------------------------------------------------------------- start/stop scripts
Step 'Creating Start/Stop scripts and desktop shortcuts'
$start = @"
@echo off
rem Starts the OSPOS database and web server, then opens OSPOS in the browser.
cd /d "%~dp0"
"%~dp0mariadb\bin\$(Split-Path -Leaf $client)" -u root -p$RootPass -h 127.0.0.1 --port=$DbPort -e "SELECT 1" >nul 2>&1
if errorlevel 1 start "OSPOS database" /min "%~dp0mariadb\bin\$(Split-Path -Leaf $mysqld)" --defaults-file="%~dp0data\my.ini"
powershell -NoProfile -Command "if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if errorlevel 1 start "OSPOS web server" /min /d "%~dp0ospos" "%~dp0php\php.exe" spark serve --host localhost --port $Port
timeout /t 5 /nobreak >nul
start "" http://localhost:$Port/
"@
$stop = @"
@echo off
rem Stops the OSPOS web server and shuts the database down cleanly.
taskkill /FI "WINDOWTITLE eq OSPOS web server*" /T /F >nul 2>&1
"%~dp0mariadb\bin\mysqladmin.exe" -u root -p$RootPass -h 127.0.0.1 --port=$DbPort shutdown
echo OSPOS stopped.
timeout /t 3 >nul
"@
[IO.File]::WriteAllText((Join-Path $InstallDir 'Start OSPOS.bat'), ($start -replace "`r?`n", "`r`n"))
[IO.File]::WriteAllText((Join-Path $InstallDir 'Stop OSPOS.bat'), ($stop -replace "`r?`n", "`r`n"))

$creds = @"
OSPOS - installed $(Get-Date -Format 'yyyy-MM-dd HH:mm')

Open OSPOS          : http://localhost:$Port/   (double-click 'Start OSPOS' first)
OSPOS login         : admin / pointofsale   (change it after the first login!)

Install folder      : $InstallDir
Shop data (back up) : $DataDir
Database            : ospos on 127.0.0.1 port $DbPort
Database user       : ospos / $DbPass
Database root       : root / $RootPass
"@
[IO.File]::WriteAllText((Join-Path $InstallDir 'credentials.txt'), ($creds -replace "`r?`n", "`r`n"))

try {
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($name in @('Start OSPOS', 'Stop OSPOS')) {
        $lnk = $shell.CreateShortcut((Join-Path $desktop "$name.lnk"))
        $lnk.TargetPath = Join-Path $InstallDir "$name.bat"
        $lnk.WorkingDirectory = $InstallDir
        $lnk.WindowStyle = 7
        $lnk.Save()
    }
} catch {
    Write-Host "    (could not create desktop shortcuts: $($_.Exception.Message))"
}

# ---------------------------------------------------------------- go
Step 'Starting OSPOS'
Start-Process -FilePath (Join-Path $InstallDir 'Start OSPOS.bat') -WorkingDirectory $InstallDir

Write-Host ''
Write-Host 'OSPOS is installed.' -ForegroundColor Green
Write-Host "  - Your browser will open http://localhost:$Port/"
Write-Host '  - First time only: click "Initialize" to create the database tables.'
Write-Host '  - Then log in with username admin and password pointofsale, and change the password.'
Write-Host "  - Use the 'Start OSPOS' and 'Stop OSPOS' shortcuts on your desktop from now on."
Write-Host "  - Passwords are saved in $InstallDir\credentials.txt"
