<#
.SYNOPSIS
    Interactive Windows cleaner for Python virtual environments.

.DESCRIPTION
    Scans every mounted local filesystem drive (C:, D:, E:, etc.) for Python
    virtual environments, including standard venv/virtualenv environments,
    Poetry environments, uv environments, Pipenv-style environments, and
    Conda environments.

    A directory is never considered deletable based on its name alone. It must
    pass structural checks such as pyvenv.cfg + a Python/activation/layout
    marker, a legacy virtualenv layout, or Conda metadata.

    Keyboard controls:
      Up/Down       Move
      PageUp/Down   Move one page
      Home/End      First/last
      Space         Select/deselect
      A             Select/deselect all unprotected environments
      Enter         Review and delete selected environments
      R             Rescan all volumes
      Ctrl+C / Q    Exit

.NOTES
    Windows PowerShell 5.1 and PowerShell 7+ compatible.
    Administrator elevation is requested for a more complete system scan.
#>

[CmdletBinding()]
param(
    [switch]$NoElevation,
    [switch]$IncludeNetworkDrives,
    [string[]]$Roots
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# ----------------------------- Platform / elevation -----------------------------

function Test-IsWindows {
    return ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

if (-not (Test-IsWindows)) {
    Write-Error 'Venv-Cleaner.ps1 is designed for Windows.'
    exit 1
}

if (-not $NoElevation -and -not (Test-IsAdministrator) -and $PSCommandPath) {
    try {
        $powerShellExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
        if ($IncludeNetworkDrives) { $arguments += '-IncludeNetworkDrives' }
        if ($Roots -and $Roots.Count -gt 0) {
            $arguments += '-Roots'
            foreach ($rootArgument in $Roots) {
                $arguments += ('"{0}"' -f $rootArgument)
            }
        }

        Start-Process -FilePath $powerShellExecutable -Verb RunAs -ArgumentList ($arguments -join ' ') -ErrorAction Stop
        exit
    } catch {
        Write-Warning "Could not elevate automatically: $($_.Exception.Message)"
        Write-Warning 'Continuing without elevation. Some folders may be inaccessible.'
        Start-Sleep -Seconds 2
    }
}

# ----------------------------- UI globals -----------------------------

$script:IconCleaner = [char]::ConvertFromUtf32(0x1F9F9)
$script:IconLock = [char]::ConvertFromUtf32(0x1F512)
$script:IconSearch = [char]::ConvertFromUtf32(0x1F50E)
$script:IconPython = [char]::ConvertFromUtf32(0x1F40D)
$script:IconKeyboard = ([string][char]0x2328) + [char]0xFE0F
$script:IconDisk = [char]::ConvertFromUtf32(0x1F4BE)
$script:SpinnerChars = @('|', '/', '-', '\')
$script:SpinCount = 0
$script:FoundItems = New-Object System.Collections.ArrayList
$script:SelectedState = @()
$script:CurrentIndex = 0
$script:MenuTop = 0
$script:RenderedLineCount = 0
$script:ActionMessage = 'Ready.'
$script:ActionColor = 'DarkGray'
$script:ScannedDirectoryCount = 0L
$script:ScanRoots = @()
$script:ActiveEnvironmentPaths = @()
$script:RunningPythonPaths = @()
$script:CondaBasePath = $null
$script:UvToolDirectory = $null
$script:UvCacheDirectory = $null
$script:PoetryVirtualenvRoots = @()
$script:PipxVenvRoots = @()

function Update-UiMetrics {
    try {
        $windowWidth = [Console]::WindowWidth
        $windowHeight = [Console]::WindowHeight
    } catch {
        $windowWidth = 100
        $windowHeight = 30
    }

    $script:UiWidth = [Math]::Min(150, [Math]::Max(40, $windowWidth - 1))
    $script:SeparatorLine = [string]::new([char]0x2500, [int]$script:UiWidth)
    $script:ViewportRows = [Math]::Max(4, $windowHeight - 12)
}

function Format-CenteredLine {
    param([string]$Text)

    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $script:UiWidth) {
        $Text = $Text.Substring(0, [Math]::Max(0, $script:UiWidth - 3)) + '...'
    }
    $leftPadding = [Math]::Max(0, [Math]::Floor(($script:UiWidth - $Text.Length) / 2))
    return ((' ' * $leftPadding) + $Text).PadRight($script:UiWidth)
}

function Show-Header {
    Update-UiMetrics
    Write-Host (Format-CenteredLine "$script:IconCleaner PYTHON VIRTUAL ENVIRONMENT CLEANER") -ForegroundColor Cyan
    Write-Host (Format-CenteredLine "$script:IconLock Verified environments only | venv, virtualenv, Poetry, uv, Pipenv, Conda") -ForegroundColor DarkGray
    Write-Host (Format-CenteredLine 'Pratik Pathak | https://github.com/zpratikpathak') -ForegroundColor Gray
    Write-Host $script:SeparatorLine -ForegroundColor DarkCyan
    Write-Host ''
}

function Write-ScanStatus {
    param(
        [string]$Root,
        [string]$CurrentPath
    )

    $script:SpinCount++
    if (($script:ScannedDirectoryCount % 180) -ne 0) { return }

    $spinner = $script:SpinnerChars[$script:SpinCount % $script:SpinnerChars.Count]
    $rootLabel = $Root
    $message = "$script:IconSearch Scanning $rootLabel  $spinner  $($script:ScannedDirectoryCount) folders checked | $($script:FoundItems.Count) envs found"
    if ($message.Length -gt $script:UiWidth) {
        $message = $message.Substring(0, [Math]::Max(0, $script:UiWidth - 3)) + '...'
    }

    try {
        [Console]::CursorLeft = 0
        Write-Host $message.PadRight($script:UiWidth) -NoNewline -ForegroundColor Cyan
    } catch {
        Write-Host $message -ForegroundColor Cyan
    }
}

# ----------------------------- Path helpers -----------------------------

function Normalize-Path {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $pathRoot = [IO.Path]::GetPathRoot($fullPath)
        if ($pathRoot -and $fullPath.Equals($pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
            # Keep the trailing separator for drive/UNC roots. "C:" is not the
            # same thing as "C:\" in PowerShell; C: means the drive current directory.
            return $pathRoot
        }
        return $fullPath.TrimEnd('\', '/')
    } catch {
        return $Path.TrimEnd('\', '/')
    }
}
function Test-PathInside {
    param(
        [string]$Child,
        [string]$Parent
    )

    $childPath = Normalize-Path $Child
    $parentPath = Normalize-Path $Parent
    if (-not $childPath -or -not $parentPath) { return $false }

    if ($childPath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $parentPath
    if (-not ($prefix.EndsWith('\') -or $prefix.EndsWith('/'))) {
        $prefix += [IO.Path]::DirectorySeparatorChar
    }
    return $childPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-IsReparsePoint {
    param([string]$Path)
    try {
        $attributes = [IO.File]::GetAttributes($Path)
        return (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Get-ScanRootList {
    $rootsFound = New-Object System.Collections.Generic.List[string]

    if ($Roots -and $Roots.Count -gt 0) {
        foreach ($requestedRoot in $Roots) {
            $normalized = Normalize-Path $requestedRoot
            if ($normalized -and (Test-Path -LiteralPath $normalized -PathType Container)) {
                $rootsFound.Add($normalized)
            }
        }
    } else {
        try {
            $fileSystemDrives = Get-PSDrive -PSProvider FileSystem
            foreach ($drive in $fileSystemDrives) {
                if (-not $drive.Root) { continue }
                $root = $drive.Root
                $isNetwork = $root.StartsWith('\\') -or ($drive.DisplayRoot -and $drive.DisplayRoot.StartsWith('\\'))
                if ($isNetwork -and -not $IncludeNetworkDrives) { continue }
                if (Test-Path -LiteralPath $root -PathType Container) {
                    $rootsFound.Add((Normalize-Path $root))
                }
            }
        } catch { }
    }

    return @($rootsFound | Sort-Object -Unique)
}

# ----------------------------- Environment metadata -----------------------------

function Initialize-EnvironmentContext {
    $active = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($env:VIRTUAL_ENV, $env:CONDA_PREFIX)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $active.Add((Normalize-Path $value))
        }
    }
    $script:ActiveEnvironmentPaths = @($active | Sort-Object -Unique)

    $running = New-Object System.Collections.Generic.List[string]
    try {
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -like 'python*' -or $_.ProcessName -like 'pypy*'
        } | ForEach-Object {
            try {
                if ($_.Path) { $running.Add((Normalize-Path $_.Path)) }
            } catch { }
        }
    } catch { }
    $script:RunningPythonPaths = @($running | Sort-Object -Unique)

    $script:CondaBasePath = $null
    try {
        if (Get-Command conda -ErrorAction SilentlyContinue) {
            $base = (& conda info --base 2>$null | Select-Object -First 1)
            if ($base) { $script:CondaBasePath = Normalize-Path $base }
        }
    } catch { }

    $script:UvToolDirectory = $null
    $script:UvCacheDirectory = $null
    try {
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            $uvTool = (& uv tool dir 2>$null | Select-Object -First 1)
            if ($uvTool) { $script:UvToolDirectory = Normalize-Path $uvTool }
            $uvCache = (& uv cache dir 2>$null | Select-Object -First 1)
            if ($uvCache) { $script:UvCacheDirectory = Normalize-Path $uvCache }
        }
    } catch { }

    $poetryRoots = New-Object System.Collections.Generic.List[string]
    if ($env:POETRY_VIRTUALENVS_PATH) {
        $poetryRoots.Add((Normalize-Path $env:POETRY_VIRTUALENVS_PATH))
    }
    if ($env:LOCALAPPDATA) {
        $poetryRoots.Add((Normalize-Path (Join-Path $env:LOCALAPPDATA 'pypoetry\Cache\virtualenvs')))
    }
    try {
        if (Get-Command poetry -ErrorAction SilentlyContinue) {
            $configuredPoetryPath = (& poetry config virtualenvs.path 2>$null | Select-Object -First 1)
            if ($configuredPoetryPath) { $poetryRoots.Add((Normalize-Path $configuredPoetryPath)) }
        }
    } catch { }
    $script:PoetryVirtualenvRoots = @($poetryRoots | Where-Object { $_ } | Sort-Object -Unique)

    # pipx environments are installed CLI applications, not disposable project
    # environments. Detect common/custom pipx homes so they can be shown but protected.
    $pipxRoots = New-Object System.Collections.Generic.List[string]
    if ($env:PIPX_HOME) {
        $pipxRoots.Add((Normalize-Path (Join-Path $env:PIPX_HOME 'venvs')))
    }
    if ($env:USERPROFILE) {
        $pipxCandidates = @(
            (Join-Path $env:USERPROFILE 'pipx\venvs')
            (Join-Path $env:USERPROFILE '.local\pipx\venvs')
        )
        foreach ($candidate in $pipxCandidates) {
            $pipxRoots.Add((Normalize-Path $candidate))
        }
    }
    if ($env:LOCALAPPDATA) {
        $pipxRoots.Add((Normalize-Path (Join-Path $env:LOCALAPPDATA 'pipx\venvs')))
    }
    $script:PipxVenvRoots = @($pipxRoots | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-EnvironmentProjectSignals {
    param([string]$EnvironmentPath)

    $parent = Split-Path -Parent $EnvironmentPath
    if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        return [PSCustomObject]@{
            HasUvLock = $false
            HasPoetryLock = $false
            HasPipfile = $false
            HasPyProject = $false
        }
    }

    return [PSCustomObject]@{
        HasUvLock = Test-Path -LiteralPath (Join-Path $parent 'uv.lock') -PathType Leaf
        HasPoetryLock = Test-Path -LiteralPath (Join-Path $parent 'poetry.lock') -PathType Leaf
        HasPipfile = Test-Path -LiteralPath (Join-Path $parent 'Pipfile') -PathType Leaf
        HasPyProject = Test-Path -LiteralPath (Join-Path $parent 'pyproject.toml') -PathType Leaf
    }
}

function Test-PythonEnvironment {
    param([string]$Path)

    $normalizedPath = Normalize-Path $Path
    if (-not $normalizedPath -or -not (Test-Path -LiteralPath $normalizedPath -PathType Container)) {
        return $null
    }

    $pyvenvCfg = Join-Path $normalizedPath 'pyvenv.cfg'
    $scriptsDir = Join-Path $normalizedPath 'Scripts'
    $binDir = Join-Path $normalizedPath 'bin'
    $libSitePackages = Join-Path $normalizedPath 'Lib\site-packages'
    $winPython = Join-Path $normalizedPath 'Scripts\python.exe'
    $winPythonW = Join-Path $normalizedPath 'Scripts\pythonw.exe'
    $activateBat = Join-Path $normalizedPath 'Scripts\activate.bat'
    $activatePs1 = Join-Path $normalizedPath 'Scripts\Activate.ps1'
    $unixPython = Join-Path $normalizedPath 'bin\python'
    $condaMeta = Join-Path $normalizedPath 'conda-meta'
    $condaHistory = Join-Path $normalizedPath 'conda-meta\history'

    $hasCfg = Test-Path -LiteralPath $pyvenvCfg -PathType Leaf
    $hasScripts = Test-Path -LiteralPath $scriptsDir -PathType Container
    $hasBin = Test-Path -LiteralPath $binDir -PathType Container
    $hasSitePackages = Test-Path -LiteralPath $libSitePackages -PathType Container
    $hasWinPython = (Test-Path -LiteralPath $winPython -PathType Leaf) -or (Test-Path -LiteralPath $winPythonW -PathType Leaf)
    $hasUnixPython = Test-Path -LiteralPath $unixPython -PathType Leaf
    $hasActivation = (Test-Path -LiteralPath $activateBat -PathType Leaf) -or (Test-Path -LiteralPath $activatePs1 -PathType Leaf)
    $hasConda = (Test-Path -LiteralPath $condaMeta -PathType Container) -and (Test-Path -LiteralPath $condaHistory -PathType Leaf)

    $kind = $null
    $provider = $null
    $confidence = $null
    $evidence = New-Object System.Collections.Generic.List[string]
    $cfgText = ''

    if ($hasConda) {
        $kind = 'Conda'
        $provider = 'Conda'
        $confidence = 'High'
        $evidence.Add('conda-meta\history')
        if (Test-Path -LiteralPath (Join-Path $normalizedPath 'python.exe') -PathType Leaf) {
            $evidence.Add('python.exe')
        }
    } elseif ($hasCfg -and ($hasScripts -or $hasBin -or $hasSitePackages -or $hasWinPython -or $hasUnixPython)) {
        $kind = 'Venv'
        $confidence = 'High'
        $evidence.Add('pyvenv.cfg')
        if ($hasWinPython -or $hasUnixPython) { $evidence.Add('Python interpreter') }
        if ($hasActivation) { $evidence.Add('activation scripts') }
        if ($hasSitePackages) { $evidence.Add('Lib\site-packages') }

        try {
            $cfgText = Get-Content -LiteralPath $pyvenvCfg -Raw -ErrorAction Stop
        } catch { $cfgText = '' }

        $signals = Get-EnvironmentProjectSignals $normalizedPath
        $isPipx = $false
        foreach ($pipxRoot in $script:PipxVenvRoots) {
            if ($pipxRoot -and (Test-PathInside $normalizedPath $pipxRoot)) {
                $isPipx = $true
                break
            }
        }

        if ($isPipx) {
            $provider = 'pipx tool'
        } elseif ($cfgText -match '(?im)^\s*uv\s*=') {
            $provider = 'uv'
        } elseif ($signals.HasUvLock) {
            $provider = 'uv project'
        } else {
            $isPoetry = $false
            foreach ($poetryRoot in $script:PoetryVirtualenvRoots) {
                if ($poetryRoot -and (Test-PathInside $normalizedPath $poetryRoot)) {
                    $isPoetry = $true
                    break
                }
            }

            if ($isPoetry -or $signals.HasPoetryLock) {
                $provider = 'Poetry'
            } elseif ($signals.HasPipfile) {
                $provider = 'Pipenv'
            } elseif ($cfgText -match '(?im)^\s*virtualenv\s*=') {
                $provider = 'virtualenv'
            } else {
                $provider = 'Python venv'
            }
        }
    } else {
        # Legacy virtualenvs can predate pyvenv.cfg. Requiring all three of
        # these markers avoids treating a random folder named "env" as a venv.
        if ($hasWinPython -and $hasActivation -and $hasSitePackages) {
            $kind = 'Venv'
            $provider = 'legacy virtualenv'
            $confidence = 'High'
            $evidence.Add('Scripts\python.exe')
            $evidence.Add('activation scripts')
            $evidence.Add('Lib\site-packages')
        } else {
            return $null
        }
    }

    $isReparse = Test-IsReparsePoint $normalizedPath
    $protectedReason = $null

    foreach ($activePath in $script:ActiveEnvironmentPaths) {
        if ($activePath -and $normalizedPath.Equals($activePath, [StringComparison]::OrdinalIgnoreCase)) {
            $protectedReason = 'Currently active environment'
            break
        }
    }

    if (-not $protectedReason -and $kind -eq 'Conda') {
        if ($script:CondaBasePath -and $normalizedPath.Equals($script:CondaBasePath, [StringComparison]::OrdinalIgnoreCase)) {
            $protectedReason = 'Conda base environment'
        } elseif ((Split-Path -Leaf $normalizedPath) -match '^(anaconda\d*|miniconda\d*|miniforge\d*|mambaforge)$') {
            $protectedReason = 'Probable Conda base installation'
        }
    }

    if (-not $protectedReason -and $script:UvToolDirectory -and (Test-PathInside $normalizedPath $script:UvToolDirectory)) {
        $protectedReason = 'uv tool environment - use uv tool uninstall'
    }

    if (-not $protectedReason -and $provider -eq 'pipx tool') {
        $protectedReason = 'pipx application environment - use pipx uninstall'
    }

    if (-not $protectedReason) {
        foreach ($pythonPath in $script:RunningPythonPaths) {
            if ($pythonPath -and (Test-PathInside $pythonPath $normalizedPath)) {
                $protectedReason = 'Python process is currently running from this environment'
                break
            }
        }
    }

    $locationType = 'Project/Custom'
    if ($provider -eq 'Poetry') { $locationType = 'Poetry' }
    elseif ($script:UvCacheDirectory -and (Test-PathInside $normalizedPath $script:UvCacheDirectory)) { $locationType = 'uv cache' }
    elseif ($isReparse) { $locationType = 'Link/Junction' }

    return [PSCustomObject]@{
        Path = $normalizedPath
        Name = Split-Path -Leaf $normalizedPath
        Kind = $kind
        Provider = $provider
        Confidence = $confidence
        Evidence = ($evidence -join ', ')
        ProtectedReason = $protectedReason
        IsProtected = [bool]$protectedReason
        IsReparsePoint = $isReparse
        LocationType = $locationType
        SizeBytes = [int64]0
        SizeCalculated = $false
        LastModified = (Get-Item -LiteralPath $normalizedPath -Force).LastWriteTime
    }
}

function Test-CommonEnvironmentName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -in @('.venv', 'venv', '.env', 'env', 'virtualenv', '.virtualenv', 'python-env', '.python-env')) {
        return $true
    }

    return ($Name -match '^(\.?(venv|env|virtualenv))[-_.]?(py)?\d*(\.\d+)?$')
}

# ----------------------------- Size helpers -----------------------------

function Get-DirectorySize {
    param([string]$Path)

    if (Test-IsReparsePoint $Path) { return [int64]0 }

    [int64]$sum = 0
    try {
        Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $sum += [int64]$_.Length
        }
    } catch { }
    return $sum
}

function Format-Size {
    param([Int64]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

# ----------------------------- Scanner -----------------------------

function Add-FoundEnvironment {
    param([PSCustomObject]$Environment)

    if (-not $Environment) { return }
    foreach ($existing in $script:FoundItems) {
        if ($existing.Path.Equals($Environment.Path, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    [void]$script:FoundItems.Add($Environment)
}

function Scan-Root {
    param([string]$Root)

    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $script:ScannedDirectoryCount++
        Write-ScanStatus -Root $Root -CurrentPath $current

        $isReparse = Test-IsReparsePoint $current
        try {
            $leafName = [IO.Path]::GetFileName($current.TrimEnd('\', '/'))
        } catch {
            $leafName = Split-Path -Leaf $current
        }

        # Strong modern/Conda markers are checked for every directory. Using
        # direct .NET file checks here is substantially cheaper than invoking
        # the PowerShell filesystem provider millions of times on a large drive.
        try {
            $hasCfg = [IO.File]::Exists([IO.Path]::Combine($current, 'pyvenv.cfg'))
            $hasCondaHistory = [IO.File]::Exists([IO.Path]::Combine($current, 'conda-meta', 'history'))
        } catch {
            $hasCfg = $false
            $hasCondaHistory = $false
        }
        $isCommonName = Test-CommonEnvironmentName $leafName

        if ($hasCfg -or $hasCondaHistory -or $isCommonName) {
            $environment = Test-PythonEnvironment $current
            if ($environment) {
                Add-FoundEnvironment $environment
                # Never recurse into a confirmed environment. Besides being much
                # faster, this prevents nested package directories from becoming
                # false candidates.
                continue
            }
        }

        # Do not follow arbitrary junctions/symlinks. If the link itself was a
        # venv, it was already recognized above.
        if ($isReparse) { continue }

        try {
            $children = [IO.Directory]::GetDirectories($current)
        } catch {
            continue
        }

        foreach ($child in $children) {
            try {
                $stack.Push($child)
            } catch { }
        }
    }
}

function Measure-FoundEnvironments {
    if ($script:FoundItems.Count -eq 0) { return }

    Write-Host ''
    for ($i = 0; $i -lt $script:FoundItems.Count; $i++) {
        $item = $script:FoundItems[$i]
        $message = "$script:IconDisk Measuring $($i + 1)/$($script:FoundItems.Count): $($item.Path)"
        if ($message.Length -gt $script:UiWidth) {
            $message = $message.Substring(0, [Math]::Max(0, $script:UiWidth - 3)) + '...'
        }
        try {
            [Console]::CursorLeft = 0
            Write-Host $message.PadRight($script:UiWidth) -NoNewline -ForegroundColor DarkGray
        } catch {
            Write-Host $message -ForegroundColor DarkGray
        }

        $item.SizeBytes = Get-DirectorySize $item.Path
        $item.SizeCalculated = $true
    }

    try {
        [Console]::CursorLeft = 0
        Write-Host (' ' * $script:UiWidth) -NoNewline
        [Console]::CursorLeft = 0
    } catch { }
}

function Invoke-FullScan {
    Clear-Host
    Show-Header
    Initialize-EnvironmentContext

    $script:FoundItems = New-Object System.Collections.ArrayList
    $script:ScannedDirectoryCount = 0L
    $script:ScanRoots = Get-ScanRootList

    if (-not $script:ScanRoots -or $script:ScanRoots.Count -eq 0) {
        Write-Host 'No filesystem volumes were available to scan.' -ForegroundColor Red
        return
    }

    $rootsText = $script:ScanRoots -join ', '
    Write-Host "$script:IconSearch Scanning volumes: $rootsText" -ForegroundColor Cyan
    Write-Host 'Detection is structural; folder names alone are never trusted.' -ForegroundColor DarkGray
    Write-Host ''

    foreach ($root in $script:ScanRoots) {
        Scan-Root $root
    }

    try {
        [Console]::CursorLeft = 0
        Write-Host (' ' * $script:UiWidth) -NoNewline
        [Console]::CursorLeft = 0
    } catch { }

    Measure-FoundEnvironments

    # Largest environments first is the most useful cleanup view.
    $sorted = @($script:FoundItems | Sort-Object @{ Expression = 'SizeBytes'; Descending = $true }, Path)
    $script:FoundItems = New-Object System.Collections.ArrayList
    foreach ($item in $sorted) { [void]$script:FoundItems.Add($item) }

    $script:SelectedState = New-Object bool[] $script:FoundItems.Count
    $script:CurrentIndex = 0

    $protectedCount = @($script:FoundItems | Where-Object { $_.IsProtected }).Count
    if ($script:FoundItems.Count -eq 0) {
        $script:ActionMessage = 'No verified Python virtual environments were found.'
        $script:ActionColor = 'Green'
    } elseif ($protectedCount -gt 0) {
        $script:ActionMessage = "Ready. $protectedCount protected environment(s) cannot be selected."
        $script:ActionColor = 'DarkGray'
    } else {
        $script:ActionMessage = 'Ready.'
        $script:ActionColor = 'DarkGray'
    }
}

# ----------------------------- Interactive menu -----------------------------

function Get-SelectedIndexes {
    $indexes = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $script:FoundItems.Count; $i++) {
        if ($script:SelectedState[$i]) { $indexes.Add($i) }
    }
    return @($indexes)
}

function Get-SelectedSize {
    [int64]$sum = 0
    for ($i = 0; $i -lt $script:FoundItems.Count; $i++) {
        if ($script:SelectedState[$i]) {
            $sum += [int64]$script:FoundItems[$i].SizeBytes
        }
    }
    return $sum
}

function Get-ViewportStart {
    if ($script:FoundItems.Count -le $script:ViewportRows) { return 0 }
    $half = [Math]::Floor($script:ViewportRows / 2)
    $start = $script:CurrentIndex - $half
    if ($start -lt 0) { $start = 0 }
    $maxStart = $script:FoundItems.Count - $script:ViewportRows
    if ($start -gt $maxStart) { $start = $maxStart }
    return $start
}

function Truncate-Text {
    param(
        [string]$Text,
        [int]$Width
    )

    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -le $Width) { return $Text.PadRight($Width) }
    if ($Width -le 3) { return $Text.Substring(0, $Width) }
    return ($Text.Substring(0, $Width - 3) + '...')
}

function Draw-Menu {
    Update-UiMetrics

    try {
        [Console]::SetCursorPosition(0, $script:MenuTop)
    } catch {
        Clear-Host
        Show-Header
        $script:MenuTop = [Console]::CursorTop
    }

    $selectedIndexes = Get-SelectedIndexes
    $selectedCount = $selectedIndexes.Count
    $selectedSize = Get-SelectedSize
    [int64]$totalSize = 0
    foreach ($item in $script:FoundItems) { $totalSize += [int64]$item.SizeBytes }
    $protectedCount = @($script:FoundItems | Where-Object { $_.IsProtected }).Count

    $statusText = "$script:IconPython ENVIRONMENTS $($script:FoundItems.Count) found | $(Format-Size $totalSize) | $selectedCount selected ($(Format-Size $selectedSize)) | $protectedCount protected"
    $controlsText = "$script:IconKeyboard [UP/DOWN] Move [SPACE] Select [A] All [ENTER] Delete [R] Rescan [Q/CTRL+C] Exit"

    Write-Host (Format-CenteredLine $statusText) -ForegroundColor Cyan
    Write-Host (Format-CenteredLine $controlsText) -ForegroundColor DarkGray
    Write-Host $script:SeparatorLine -ForegroundColor DarkCyan

    $compact = ($script:UiWidth -lt 95)
    if ($compact) {
        $heading = '    PROVIDER        SIZE       PATH'
    } else {
        $heading = '    PROVIDER          SIZE       MODIFIED     PATH'
    }
    Write-Host (Truncate-Text $heading $script:UiWidth) -ForegroundColor DarkGray

    $start = Get-ViewportStart
    $end = [Math]::Min($script:FoundItems.Count - 1, $start + $script:ViewportRows - 1)

    if ($script:FoundItems.Count -eq 0) {
        Write-Host (Format-CenteredLine 'No verified environments found.') -ForegroundColor Green
    } else {
        for ($i = $start; $i -le $end; $i++) {
            $item = $script:FoundItems[$i]
            $selected = $script:SelectedState[$i]
            $box = if ($item.IsProtected) { '[!]' } elseif ($selected) { '[X]' } else { '[ ]' }
            $pointer = if ($i -eq $script:CurrentIndex) { '>' } else { ' ' }
            $provider = Truncate-Text $item.Provider 16
            $sizeText = if ($item.IsReparsePoint) { '<link>' } else { Format-Size $item.SizeBytes }
            $sizeText = $sizeText.PadLeft(9)

            if ($compact) {
                $prefixLength = 1 + 1 + 3 + 1 + 16 + 1 + 9 + 1
                $pathWidth = [Math]::Max(8, $script:UiWidth - $prefixLength)
                $line = "$pointer$box $provider $sizeText $(Truncate-Text $item.Path $pathWidth)"
            } else {
                $modified = $item.LastModified.ToString('yyyy-MM-dd')
                $prefixLength = 1 + 3 + 1 + 16 + 1 + 9 + 1 + 10 + 1
                $pathWidth = [Math]::Max(8, $script:UiWidth - $prefixLength)
                $line = "$pointer$box $provider $sizeText $modified $(Truncate-Text $item.Path $pathWidth)"
            }

            $line = Truncate-Text $line $script:UiWidth
            if ($i -eq $script:CurrentIndex) {
                Write-Host $line -ForegroundColor Cyan
            } elseif ($item.IsProtected) {
                Write-Host $line -ForegroundColor Yellow
            } elseif ($selected) {
                Write-Host $line -ForegroundColor Green
            } else {
                Write-Host $line -ForegroundColor Gray
            }
        }
    }

    Write-Host $script:SeparatorLine -ForegroundColor DarkCyan

    if ($script:FoundItems.Count -gt 0) {
        $current = $script:FoundItems[$script:CurrentIndex]
        $detail = "Verified: $($current.Evidence)"
        if ($current.IsProtected) { $detail += " | PROTECTED: $($current.ProtectedReason)" }
        elseif ($current.IsReparsePoint) { $detail += ' | Link/junction: deletion removes the link, not its target contents.' }
        $detailColor = if ($current.IsProtected) { 'Yellow' } else { 'DarkGray' }
        Write-Host (Truncate-Text $detail $script:UiWidth) -ForegroundColor $detailColor
        Write-Host (Truncate-Text ("Path: " + $current.Path) $script:UiWidth) -ForegroundColor DarkGray
    } else {
        Write-Host (Truncate-Text '' $script:UiWidth)
        Write-Host (Truncate-Text '' $script:UiWidth)
    }

    Write-Host (Truncate-Text $script:ActionMessage $script:UiWidth) -ForegroundColor $script:ActionColor

    $visibleRows = if ($script:FoundItems.Count -eq 0) { 1 } else { ($end - $start + 1) }
    $currentLineCount = $visibleRows + 8
    for ($lineIndex = $currentLineCount; $lineIndex -lt $script:RenderedLineCount; $lineIndex++) {
        Write-Host (' ' * $script:UiWidth)
    }
    $script:RenderedLineCount = $currentLineCount
}

function Toggle-AllSelectable {
    if ($script:FoundItems.Count -eq 0) { return }

    $selectAll = $false
    for ($i = 0; $i -lt $script:FoundItems.Count; $i++) {
        if (-not $script:FoundItems[$i].IsProtected -and -not $script:SelectedState[$i]) {
            $selectAll = $true
            break
        }
    }

    for ($i = 0; $i -lt $script:FoundItems.Count; $i++) {
        if (-not $script:FoundItems[$i].IsProtected) {
            $script:SelectedState[$i] = $selectAll
        }
    }
}

# ----------------------------- Deletion -----------------------------

function Remove-EnvironmentDirectory {
    param([PSCustomObject]$Environment)

    $path = $Environment.Path

    if ($Environment.IsReparsePoint) {
        # Remove only the junction/symlink itself. Do not recurse into its target.
        $process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'rmdir', ('"{0}"' -f $path)) -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -ne 0 -or (Test-Path -LiteralPath $path)) {
            throw "Could not remove link/junction: $path"
        }
        return
    }

    if ($Environment.Kind -eq 'Conda' -and (Get-Command conda -ErrorAction SilentlyContinue)) {
        try {
            & conda env remove --prefix $path -y | Out-Null
            if (-not (Test-Path -LiteralPath $path)) { return }
        } catch { }
        # Fall through to direct deletion only for non-base environments.
    }

    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
}

function Confirm-AndDeleteSelected {
    $selectedIndexes = Get-SelectedIndexes
    if ($selectedIndexes.Count -eq 0) {
        $script:ActionMessage = 'No environments selected.'
        $script:ActionColor = 'Yellow'
        return
    }

    Clear-Host
    Show-Header

    [int64]$total = 0
    Write-Host "Selected environments:" -ForegroundColor Cyan
    Write-Host ''
    foreach ($index in $selectedIndexes) {
        $item = $script:FoundItems[$index]
        $total += [int64]$item.SizeBytes
        Write-Host ("  {0,-16} {1,10}  {2}" -f $item.Provider, (Format-Size $item.SizeBytes), $item.Path) -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host ("Potential disk space to recover: {0}" -f (Format-Size $total)) -ForegroundColor Cyan
    Write-Host 'Each directory will be structurally re-validated immediately before deletion.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Type DELETE to permanently remove the selected environment(s).' -ForegroundColor Yellow
    $confirmation = Read-Host 'Confirmation'

    if ($confirmation -cne 'DELETE') {
        $script:ActionMessage = 'Deletion cancelled.'
        $script:ActionColor = 'Yellow'
        Clear-Host
        Show-Header
        $script:MenuTop = [Console]::CursorTop
        $script:RenderedLineCount = 0
        return
    }

    $successfulPaths = New-Object System.Collections.Generic.List[string]
    $failedMessages = New-Object System.Collections.Generic.List[string]

    # Refresh protection state immediately before destructive work.
    Initialize-EnvironmentContext
    foreach ($index in $selectedIndexes) {
        $target = $script:FoundItems[$index]

        # Safety: status can change between scan and deletion.
        $revalidated = Test-PythonEnvironment $target.Path
        if (-not $revalidated) {
            $failedMessages.Add("Skipped (no longer verifies as a venv): $($target.Path)")
            continue
        }
        if ($revalidated.IsProtected) {
            $failedMessages.Add("Skipped (now protected: $($revalidated.ProtectedReason)): $($target.Path)")
            continue
        }

        try {
            Write-Host "Removing $($target.Path) ..." -ForegroundColor DarkGray
            Remove-EnvironmentDirectory $revalidated
            if (Test-Path -LiteralPath $target.Path) {
                throw 'Directory still exists after removal attempt.'
            }
            $successfulPaths.Add($target.Path)
        } catch {
            $failedMessages.Add("Failed: $($target.Path) - $($_.Exception.Message)")
        }
    }

    # Rebuild list using paths instead of stale indexes.
    $remaining = New-Object System.Collections.ArrayList
    foreach ($item in $script:FoundItems) {
        $wasRemoved = $false
        foreach ($removedPath in $successfulPaths) {
            if ($item.Path.Equals($removedPath, [StringComparison]::OrdinalIgnoreCase)) {
                $wasRemoved = $true
                break
            }
        }
        if (-not $wasRemoved) { [void]$remaining.Add($item) }
    }
    $script:FoundItems = $remaining
    $script:SelectedState = New-Object bool[] $script:FoundItems.Count
    if ($script:FoundItems.Count -eq 0) { $script:CurrentIndex = 0 }
    elseif ($script:CurrentIndex -ge $script:FoundItems.Count) { $script:CurrentIndex = $script:FoundItems.Count - 1 }

    if ($failedMessages.Count -eq 0) {
        $script:ActionMessage = "Removed $($successfulPaths.Count) environment(s), recovering up to $(Format-Size $total)."
        $script:ActionColor = 'Green'
    } elseif ($successfulPaths.Count -gt 0) {
        $script:ActionMessage = "Removed $($successfulPaths.Count); $($failedMessages.Count) skipped/failed. Press R to rescan."
        $script:ActionColor = 'Yellow'
    } else {
        $script:ActionMessage = "Nothing was removed; $($failedMessages.Count) item(s) skipped/failed."
        $script:ActionColor = 'Red'
    }

    if ($failedMessages.Count -gt 0) {
        Write-Host ''
        foreach ($failure in $failedMessages) { Write-Host $failure -ForegroundColor Yellow }
        Write-Host ''
        Write-Host 'Press any key to return to the menu...' -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    }

    Clear-Host
    Show-Header
    $script:MenuTop = [Console]::CursorTop
    $script:RenderedLineCount = 0
}

# ----------------------------- Main -----------------------------

try {
    Invoke-FullScan

    Clear-Host
    Show-Header
    $script:MenuTop = [Console]::CursorTop
    [Console]::CursorVisible = $false
    Draw-Menu

    $previousTreatControlCAsInput = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true

    $keepRunning = $true
    while ($keepRunning) {
        $keyInfo = [Console]::ReadKey($true)
        $isControlC = ($keyInfo.Key -eq [ConsoleKey]::C) -and (($keyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
        if ($isControlC) { break }

        switch ($keyInfo.Key) {
            ([ConsoleKey]::Q) {
                $keepRunning = $false
            }
            ([ConsoleKey]::UpArrow) {
                if ($script:FoundItems.Count -gt 0 -and $script:CurrentIndex -gt 0) { $script:CurrentIndex-- }
                Draw-Menu
            }
            ([ConsoleKey]::DownArrow) {
                if ($script:FoundItems.Count -gt 0 -and $script:CurrentIndex -lt ($script:FoundItems.Count - 1)) { $script:CurrentIndex++ }
                Draw-Menu
            }
            ([ConsoleKey]::PageUp) {
                if ($script:FoundItems.Count -gt 0) {
                    $script:CurrentIndex = [Math]::Max(0, $script:CurrentIndex - $script:ViewportRows)
                }
                Draw-Menu
            }
            ([ConsoleKey]::PageDown) {
                if ($script:FoundItems.Count -gt 0) {
                    $script:CurrentIndex = [Math]::Min($script:FoundItems.Count - 1, $script:CurrentIndex + $script:ViewportRows)
                }
                Draw-Menu
            }
            ([ConsoleKey]::Home) {
                if ($script:FoundItems.Count -gt 0) { $script:CurrentIndex = 0 }
                Draw-Menu
            }
            ([ConsoleKey]::End) {
                if ($script:FoundItems.Count -gt 0) { $script:CurrentIndex = $script:FoundItems.Count - 1 }
                Draw-Menu
            }
            ([ConsoleKey]::Spacebar) {
                if ($script:FoundItems.Count -gt 0) {
                    $item = $script:FoundItems[$script:CurrentIndex]
                    if ($item.IsProtected) {
                        $script:ActionMessage = "Protected: $($item.ProtectedReason)"
                        $script:ActionColor = 'Yellow'
                    } else {
                        $script:SelectedState[$script:CurrentIndex] = -not $script:SelectedState[$script:CurrentIndex]
                        $script:ActionMessage = 'Ready.'
                        $script:ActionColor = 'DarkGray'
                    }
                }
                Draw-Menu
            }
            ([ConsoleKey]::A) {
                Toggle-AllSelectable
                $script:ActionMessage = 'Selection updated.'
                $script:ActionColor = 'DarkGray'
                Draw-Menu
            }
            ([ConsoleKey]::Enter) {
                [Console]::CursorVisible = $true
                Confirm-AndDeleteSelected
                [Console]::CursorVisible = $false
                Draw-Menu
            }
            ([ConsoleKey]::R) {
                [Console]::CursorVisible = $true
                Invoke-FullScan
                Clear-Host
                Show-Header
                $script:MenuTop = [Console]::CursorTop
                $script:RenderedLineCount = 0
                [Console]::CursorVisible = $false
                Draw-Menu
            }
        }
    }
} finally {
    try {
        if ($null -ne $previousTreatControlCAsInput) {
            [Console]::TreatControlCAsInput = $previousTreatControlCAsInput
        }
    } catch { }
    try { [Console]::CursorVisible = $true } catch { }
    $ProgressPreference = 'Continue'
    Write-Host ''
}
