#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Builds a reverse-engineering / malware-analysis workstation.

.DESCRIPTION
    Installs and configures:
      * PowerShell execution policy (LocalMachine) set to Unrestricted
      * Eclipse Temurin OpenJDK (JAVA_HOME + PATH)
      * Ghidra (latest GitHub release, GHIDRA_INSTALL_DIR + desktop shortcut)
      * WinDbg (winget, with the aka.ms App Installer package as fallback)
      * Python 3.10 (all users, PATH) plus the speakeasy-emulator package
      * C:\demo working directory, added to the Microsoft Defender exclusion list

    Every step is idempotent: re-running skips anything already present.
    A transcript is written to $InstallRoot\logs.

.PARAMETER InstallRoot
    Base directory for JDK and Ghidra. Default C:\Tools.

.PARAMETER DemoPath
    Working directory to create and exclude from Defender. Default C:\demo.

.PARAMETER JdkVersion
    Temurin feature release. Ghidra 11.x requires 21. Default 21.

.PARAMETER PythonVersion
    Full CPython 3.10 patch version. 3.10.11 is the last 3.10 with a binary
    installer, so there is no reason to change this.

.PARAMETER ExecutionPolicyLevel
    Machine execution policy to set. Default Unrestricted. Appropriate for a
    dedicated lab VM; not recommended on a general-purpose machine.

.PARAMETER Force
    Reinstall components even if they are already detected.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-AnalysisLab.ps1

.EXAMPLE
    .\Install-AnalysisLab.ps1 -InstallRoot D:\RE -SkipWinDbg
#>

[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\Tools',
    [string]$DemoPath    = 'C:\demo',

    [ValidateSet('17', '21')]
    [string]$JdkVersion = '21',

    [string]$PythonVersion = '3.10.11',
    [string]$PythonRoot    = 'C:\Python310',

    [ValidateSet('Restricted', 'AllSigned', 'RemoteSigned', 'Unrestricted', 'Bypass')]
    [string]$ExecutionPolicyLevel = 'Unrestricted',

    # Sample/tooling files to stage into the demo directory for analysis.
    [string]$LabRepo  = 'nick-neal/msfvenom-win-reveng-lab',
    [string[]]$LabFiles = @('listener.ps1', 'shellcode.exe'),

    [switch]$SkipExecutionPolicy,
    [switch]$SkipJdk,
    [switch]$SkipGhidra,
    [switch]$SkipWinDbg,
    [switch]$SkipPython,
    [switch]$SkipDefenderExclusion,
    [switch]$SkipLabFiles,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # ~10x faster Invoke-WebRequest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

$script:LogDir   = Join-Path $InstallRoot 'logs'
$script:LogFile  = Join-Path $LogDir ('install-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$script:WorkDir  = Join-Path $env:TEMP ('lab-setup-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
$script:Results  = [ordered]@{}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'FAIL')][string]$Level = 'INFO'
    )

    $stamp = Get-Date -Format 'HH:mm:ss'
    $line  = '[{0}] [{1,-4}] {2}' -f $stamp, $Level, $Message

    $color = switch ($Level) {
        'STEP' { 'Cyan' }
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }

    if ($Level -eq 'STEP') { Write-Host '' }
    Write-Host $line -ForegroundColor $color

    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Get-RemoteFile {
    <#  Download with retries. Returns the output path. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [hashtable]$Headers = @{},
        [int]$Retries = 3
    )

    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Write-Log "Downloading $Uri (attempt $i/$Retries)"
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -Headers $Headers -TimeoutSec 300
            $mb = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
            Write-Log "Saved $([IO.Path]::GetFileName($OutFile)) ($mb MB)"
            return $OutFile
        }
        catch {
            Write-Log "Download failed: $($_.Exception.Message)" 'WARN'
            if ($i -eq $Retries) { throw }
            Start-Sleep -Seconds (5 * $i)
        }
    }
}

function Get-GitHubRepoFile {
    <#
        Resolves a file inside a public GitHub repo by its leaf name (so it works
        whether the file sits at the repo root or in a subdirectory), downloads
        the raw blob, and returns the local path. Uses the repo's default branch.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,        # 'owner/name'
        [Parameter(Mandatory)][string]$FileName,    # e.g. 'shellcode.exe'
        [Parameter(Mandatory)][string]$Destination  # full output path
    )

    $headers = @{ 'User-Agent' = 'PowerShell-LabSetup'; 'Accept' = 'application/vnd.github+json' }

    Write-Log "Resolving $FileName in $Repo"
    $meta   = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo" -Headers $headers -UseBasicParsing -TimeoutSec 60
    $branch = $meta.default_branch

    $treeUri = "https://api.github.com/repos/$Repo/git/trees/$branch" + '?recursive=1'
    $tree    = Invoke-RestMethod -Uri $treeUri -Headers $headers -UseBasicParsing -TimeoutSec 60

    $entry = $tree.tree |
             Where-Object { $_.type -eq 'blob' -and (($_.path -split '/')[-1] -ieq $FileName) } |
             Select-Object -First 1

    if (-not $entry) { throw "'$FileName' not found in $Repo (default branch: $branch)." }

    $raw = "https://raw.githubusercontent.com/$Repo/$branch/$($entry.path)"
    Get-RemoteFile -Uri $raw -OutFile $Destination -Headers $headers | Out-Null
    return $Destination
}

function Set-MachineEnvVar {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)

    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
    Set-Item -Path "Env:$Name" -Value $Value          # make it live in this session too
    Write-Log "Set $Name = $Value"
}

function Add-MachinePath {
    param([Parameter(Mandatory)][string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts   = $current -split ';' | Where-Object { $_ -ne '' }

    if ($parts -contains $Directory.TrimEnd('\')) {
        Write-Log "PATH already contains $Directory"
    }
    else {
        [Environment]::SetEnvironmentVariable('Path', ($current.TrimEnd(';') + ';' + $Directory), 'Machine')
        Write-Log "Added $Directory to machine PATH"
    }

    if (($env:Path -split ';') -notcontains $Directory) {
        $env:Path = $env:Path.TrimEnd(';') + ';' + $Directory
    }
}

function Expand-ToDirectory {
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$Destination)

    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    Write-Log "Extracting $([IO.Path]::GetFileName($ZipPath)) -> $Destination"

    # Expand-Archive is slow on large zips; the shell class is faster and is
    # present on every supported OS.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function New-Shortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [string]$WorkingDirectory
    )

    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk   = $shell.CreateShortcut($Path)
        $lnk.TargetPath = $Target
        if ($WorkingDirectory) { $lnk.WorkingDirectory = $WorkingDirectory }
        $lnk.Save()
        Write-Log "Shortcut created: $Path"
    }
    catch {
        Write-Log "Could not create shortcut: $($_.Exception.Message)" 'WARN'
    }
}

function Invoke-Step {
    <#  Runs a component installer, records pass/fail, never aborts the run. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Skip
    )

    if ($Skip) {
        Write-Log "$Name : skipped by parameter" 'WARN'
        $script:Results[$Name] = 'Skipped'
        return
    }

    Write-Log "===== $Name =====" 'STEP'
    try {
        & $Action
        $script:Results[$Name] = 'OK'
        Write-Log "$Name completed" 'OK'
    }
    catch {
        $script:Results[$Name] = "Failed - $($_.Exception.Message)"
        Write-Log "$Name failed: $($_.Exception.Message)" 'FAIL'
        Write-Log $_.ScriptStackTrace 'FAIL'
    }
}

# ---------------------------------------------------------------------------
# Component installers
# ---------------------------------------------------------------------------

function Set-ScriptExecutionPolicy {
    <#
        Sets the machine-wide PowerShell execution policy. On a dedicated analysis
        VM this is convenient - unsigned lab scripts (e.g. listener.ps1) then run
        without prompting. It is NOT something to do on a general-purpose machine.
        Note 'Unrestricted' still warns once for files that carry a Mark-of-the-Web
        unless they have been unblocked.
    #>
    $scope = 'LocalMachine'

    $current = Get-ExecutionPolicy -Scope $scope
    if ($current -eq $ExecutionPolicyLevel -and -not $Force) {
        Write-Log "Execution policy ($scope) already $ExecutionPolicyLevel"
    }
    else {
        try {
            Set-ExecutionPolicy -ExecutionPolicy $ExecutionPolicyLevel -Scope $scope -Force -ErrorAction Stop
            Write-Log "Set execution policy ($scope) = $ExecutionPolicyLevel"
        }
        catch {
            Write-Log "Could not set execution policy: $($_.Exception.Message)" 'WARN'
            Write-Log 'A Group Policy (MachinePolicy/UserPolicy scope) may enforce a policy that overrides this and cannot be changed here.' 'WARN'
        }
    }

    # Effective policy is the winner across scopes: GPO > Process > CurrentUser > LocalMachine.
    Write-Log "Effective execution policy: $(Get-ExecutionPolicy)"
}

function Install-OpenJdk {
    $target = Join-Path $InstallRoot "jdk-$JdkVersion"

    if ((Test-Path (Join-Path $target 'bin\java.exe')) -and -not $Force) {
        Write-Log "JDK already present at $target"
    }
    else {
        if (Test-Path $target) { Remove-Item $target -Recurse -Force }

        # Adoptium redirects this to the current GA build for the feature release.
        $uri = "https://api.adoptium.net/v3/binary/latest/$JdkVersion/ga/windows/x64/jdk/hotspot/normal/eclipse"
        $zip = Get-RemoteFile -Uri $uri -OutFile (Join-Path $WorkDir 'temurin-jdk.zip')

        $staging = Join-Path $WorkDir 'jdk-staging'
        Expand-ToDirectory -ZipPath $zip -Destination $staging

        # The archive contains a single top-level folder such as jdk-21.0.4+7.
        $inner = Get-ChildItem -Path $staging -Directory | Select-Object -First 1
        Move-Item -Path $inner.FullName -Destination $target
    }

    Set-MachineEnvVar -Name 'JAVA_HOME' -Value $target
    Add-MachinePath -Directory (Join-Path $target 'bin')

    # `java -version` writes its banner to STDERR by design. Merging that with
    # 2>&1 while $ErrorActionPreference is 'Stop' makes PowerShell 5.1 promote the
    # normal output to a terminating NativeCommandError - which false-fails this
    # step even though the JDK installed fine. Run the probe in a child scope with
    # the preference relaxed so stderr is treated as plain text, and confirm the
    # install by checking that java.exe actually exists.
    $javaExe = Join-Path $target 'bin\java.exe'
    if (-not (Test-Path $javaExe)) { throw "java.exe not found at $javaExe after install" }

    $version = & {
        $ErrorActionPreference = 'Continue'
        (& $javaExe -version 2>&1 | Select-Object -First 1 | Out-String).Trim()
    }
    Write-Log "java -version: $version"
}

function Install-Ghidra {
    $existing = Get-ChildItem -Path $InstallRoot -Directory -Filter 'ghidra_*_PUBLIC' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1

    if ($existing -and -not $Force) {
        Write-Log "Ghidra already present at $($existing.FullName)"
        $ghidraDir = $existing.FullName
    }
    else {
        $headers = @{ 'User-Agent' = 'PowerShell-LabSetup'; 'Accept' = 'application/vnd.github+json' }
        $api     = 'https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest'

        Write-Log 'Querying GitHub for the latest Ghidra release'
        $release = Invoke-RestMethod -Uri $api -Headers $headers -UseBasicParsing -TimeoutSec 60

        $asset = $release.assets | Where-Object { $_.name -like 'ghidra_*_PUBLIC_*.zip' } | Select-Object -First 1
        if (-not $asset) { throw 'No Ghidra .zip asset found on the latest release.' }

        Write-Log "Latest release: $($release.tag_name) ($($asset.name))"
        $zip = Get-RemoteFile -Uri $asset.browser_download_url -OutFile (Join-Path $WorkDir $asset.name)

        if ($existing) { Remove-Item $existing.FullName -Recurse -Force }
        Expand-ToDirectory -ZipPath $zip -Destination $InstallRoot

        $ghidraDir = (Get-ChildItem -Path $InstallRoot -Directory -Filter 'ghidra_*_PUBLIC' |
                      Sort-Object Name -Descending | Select-Object -First 1).FullName
    }

    Set-MachineEnvVar -Name 'GHIDRA_INSTALL_DIR' -Value $ghidraDir

    $runBat = Join-Path $ghidraDir 'ghidraRun.bat'
    if (Test-Path $runBat) {
        New-Shortcut -Path (Join-Path $env:PUBLIC 'Desktop\Ghidra.lnk') -Target $runBat -WorkingDirectory $ghidraDir
    }
}

function Install-WinDbg {
    if ((Get-Command windbgx.exe -ErrorAction SilentlyContinue) -or
        (Get-AppxPackage -Name 'Microsoft.WinDbg' -ErrorAction SilentlyContinue)) {
        if (-not $Force) { Write-Log 'WinDbg already installed'; return }
    }

    # Preferred path: winget.
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Log 'Installing WinDbg via winget'
        $args = @('install', '--id', 'Microsoft.WinDbg', '--exact', '--silent',
                  '--accept-package-agreements', '--accept-source-agreements')
        $p = Start-Process -FilePath 'winget.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow

        # 0 = installed, -1978335189 (0x8A15002B) = no applicable upgrade / already installed
        if ($p.ExitCode -in 0, -1978335189) { Write-Log 'winget install finished'; return }
        Write-Log "winget returned $($p.ExitCode); falling back to App Installer" 'WARN'
    }
    else {
        Write-Log 'winget not available; using App Installer fallback' 'WARN'
    }

    # Fallback: the MSIX App Installer manifest published by Microsoft.
    $manifest = Get-RemoteFile -Uri 'https://aka.ms/windbg/download' -OutFile (Join-Path $WorkDir 'windbg.appinstaller')
    Add-AppxPackage -AppInstallerFile $manifest -ErrorAction Stop
    Write-Log 'WinDbg installed from App Installer manifest'
}

function Install-Python {
    $python = Join-Path $PythonRoot 'python.exe'

    if ((Test-Path $python) -and -not $Force) {
        Write-Log "Python already present at $PythonRoot"
    }
    else {
        $file = "python-$PythonVersion-amd64.exe"
        $uri  = "https://www.python.org/ftp/python/$PythonVersion/$file"
        $exe  = Get-RemoteFile -Uri $uri -OutFile (Join-Path $WorkDir $file)

        $args = @(
            '/quiet',
            'InstallAllUsers=1',
            "TargetDir=$PythonRoot",
            'PrependPath=1',
            'Include_pip=1',
            'Include_test=0',
            'AssociateFiles=1',
            'Shortcuts=1',
            "/log `"$(Join-Path $LogDir 'python-install.log')`""
        )

        Write-Log "Installing Python $PythonVersion to $PythonRoot"
        $p = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -NoNewWindow

        if ($p.ExitCode -eq 3010) { Write-Log 'Python installer requests a reboot (3010)' 'WARN' }
        elseif ($p.ExitCode -ne 0) { throw "Python installer exited with code $($p.ExitCode)" }
    }

    if (-not (Test-Path $python)) { throw "python.exe not found at $python after install" }

    Add-MachinePath -Directory $PythonRoot
    Add-MachinePath -Directory (Join-Path $PythonRoot 'Scripts')

    # `python --version` writes to STDOUT, so the 2>&1 merge here is safe.
    Write-Log ('Interpreter: ' + (& $python --version 2>&1))

    Write-Log 'Upgrading pip'
    & $python -m pip install --upgrade pip --disable-pip-version-check --no-warn-script-location
    if ($LASTEXITCODE -ne 0) { Write-Log "pip upgrade returned $LASTEXITCODE" 'WARN' }

    Write-Log 'Installing speakeasy-emulator'
    & $python -m pip install speakeasy-emulator --disable-pip-version-check --no-warn-script-location
    if ($LASTEXITCODE -ne 0) { throw "pip install speakeasy-emulator failed with code $LASTEXITCODE" }

    # Import in a child scope with the error preference relaxed: dependency imports
    # (unicorn/capstone/pefile) can emit warnings to stderr, which would otherwise
    # become a terminating error under $ErrorActionPreference='Stop'. Verify by
    # exit code rather than by inspecting the merged text.
    $check = & {
        $ErrorActionPreference = 'Continue'
        (& $python -c "import speakeasy; print(getattr(speakeasy, '__version__', 'installed'))" 2>&1 | Out-String).Trim()
    }
    if ($LASTEXITCODE -ne 0) { throw "speakeasy import failed (exit $LASTEXITCODE): $check" }
    Write-Log "speakeasy import check: $check"
}

function Set-DemoDirectory {
    if (-not (Test-Path $DemoPath)) {
        New-Item -ItemType Directory -Path $DemoPath -Force | Out-Null
        Write-Log "Created $DemoPath"
    }
    else {
        Write-Log "$DemoPath already exists"
    }

    if ($SkipDefenderExclusion) {
        Write-Log 'Defender exclusion skipped by parameter' 'WARN'
        return
    }

    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
        Write-Log 'Defender cmdlets unavailable (feature removed or third-party AV) - exclusion not set' 'WARN'
        return
    }

    try {
        $existing = (Get-MpPreference).ExclusionPath
        if ($existing -contains $DemoPath) {
            Write-Log "$DemoPath is already excluded"
        }
        else {
            Add-MpPreference -ExclusionPath $DemoPath -ErrorAction Stop
            Write-Log "Added Defender path exclusion for $DemoPath"
        }

        $verify = (Get-MpPreference).ExclusionPath
        if ($verify -contains $DemoPath) { Write-Log 'Exclusion verified' }
        else { Write-Log 'Exclusion did not persist - it may be blocked by tamper protection or policy' 'WARN' }
    }
    catch {
        Write-Log "Could not set exclusion: $($_.Exception.Message)" 'WARN'
        Write-Log 'Disable Tamper Protection, or set the exclusion via GPO/Intune, then retry.' 'WARN'
    }
}

function Get-LabFiles {
    if (-not (Test-Path $DemoPath)) {
        New-Item -ItemType Directory -Path $DemoPath -Force | Out-Null
        Write-Log "Created $DemoPath"
    }

    foreach ($name in $LabFiles) {
        $dest = Join-Path $DemoPath $name

        if ((Test-Path $dest) -and -not $Force) {
            Write-Log "$name already present in $DemoPath"
        }
        else {
            if (Test-Path $dest) { Remove-Item $dest -Force }
            Get-GitHubRepoFile -Repo $LabRepo -FileName $name -Destination $dest | Out-Null
        }

        # Strip the Mark-of-the-Web (Zone.Identifier) so SmartScreen / zone checks
        # don't block the file when you open it inside the lab. This is exactly why
        # it belongs in an isolated VM, not on a working machine.
        Unblock-File -Path $dest
        Write-Log "Unblocked $dest"
    }

    Write-Log "Staged $($LabFiles.Count) file(s) in $DemoPath" 'OK'
    Write-Log 'These are live analysis artifacts. Only open/run them inside an isolated, snapshotted VM with no bridged networking.' 'WARN'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir      -Force | Out-Null
New-Item -ItemType Directory -Path $WorkDir     -Force | Out-Null

Write-Log "Analysis lab setup starting. Log: $LogFile" 'STEP'
Write-Log "Host: $env:COMPUTERNAME   User: $env:USERNAME   PS: $($PSVersionTable.PSVersion)"
Write-Log "InstallRoot: $InstallRoot   DemoPath: $DemoPath   Scratch: $WorkDir"

try {
    Invoke-Step -Name 'Execution policy'   -Skip:$SkipExecutionPolicy -Action { Set-ScriptExecutionPolicy }
    Invoke-Step -Name 'OpenJDK'            -Skip:$SkipJdk    -Action { Install-OpenJdk }
    Invoke-Step -Name 'Ghidra'             -Skip:$SkipGhidra -Action { Install-Ghidra }
    Invoke-Step -Name 'WinDbg'             -Skip:$SkipWinDbg -Action { Install-WinDbg }
    Invoke-Step -Name 'Python + Speakeasy' -Skip:$SkipPython -Action { Install-Python }
    Invoke-Step -Name 'Demo directory'     -Action { Set-DemoDirectory }
    Invoke-Step -Name 'Lab files'          -Skip:$SkipLabFiles -Action { Get-LabFiles }
}
finally {
    if (Test-Path $WorkDir) {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned scratch directory"
    }
}

Write-Log '===== Summary =====' 'STEP'
foreach ($key in $Results.Keys) {
    $level = if ($Results[$key] -eq 'OK') { 'OK' } elseif ($Results[$key] -eq 'Skipped') { 'WARN' } else { 'FAIL' }
    Write-Log ('{0,-22} {1}' -f $key, $Results[$key]) $level
}

Write-Host ''
Write-Log "Full log: $LogFile"
Write-Log 'Open a new terminal so the updated PATH, JAVA_HOME and GHIDRA_INSTALL_DIR are picked up.'

if ($Results.Values -match '^Failed') { exit 1 } else { exit 0 }