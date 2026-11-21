#Requires -Version 7.6

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'Continue'

$Repo = 'korarei/AviUtl2_Astra'
$ApiBase = "https://api.github.com/repos/$Repo"

class PartialVersion {
    [Nullable[int]] $Major
    [Nullable[int]] $Minor
    [Nullable[int]] $Patch
    [string] $Pre

    [semver] ToSemVer() {
        return [semver]::new(($this.Major ?? 0), ($this.Minor ?? 0), ($this.Patch ?? 0), $this.Pre)
    }
}

class Comparator {
    [string] $Op
    [semver] $Version

    Comparator([string]$op, [semver]$version) {
        $this.Op = $op
        $this.Version = $version
    }
}

function Get-Platform {
    $os = $env:RUNNER_OS
    if ([string]::IsNullOrWhiteSpace($os)) {
        if ($IsWindows) {
            $os = 'Windows'
        } elseif ($IsLinux) {
            $os = 'Linux'
        } elseif ($IsMacOS) {
            $os = 'macOS'
        } else {
            $os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        }
    }

    $arch = $env:RUNNER_ARCH
    if ([string]::IsNullOrWhiteSpace($arch)) {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }

    $arch = $arch.ToLowerInvariant()

    if ($os -eq 'Windows' -and $arch -in 'x64', 'arm64') {
        $archiveType = 'zip'
        $exeName = 'astra.exe'
    } elseif ($os -eq 'Linux' -and $arch -eq 'x64') {
        $archiveType = 'tar.gz'
        $exeName = 'astra'
    } else {
        throw "unsupported platform '$os/$arch' for $Repo, which provides windows (x64, arm64) and linux (x64) binaries"
    }

    $assetLabel = "$($os.ToLowerInvariant())-$arch.$archiveType"
    return [PSCustomObject]@{
        OS = $os
        Arch = $arch
        ArchiveType = $archiveType
        ExeName = $exeName
        AssetLabel = $assetLabel
        AssetRegex = "^astra-(?:.+?-)?$([regex]::Escape($assetLabel))$"
    }
}

function ConvertFrom-SemVer {
    param([string]$Text)

    $partial = ConvertFrom-PartialVersion $Text

    if ($null -ne $partial -and $null -ne $partial.Patch) {
        return $partial.ToSemVer()
    }
}

function ConvertFrom-PartialVersion {
    param([string]$Text)

    $part = '[xX*]|0|[1-9][0-9]*'
    $pre = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    $pattern = "^v?(?<major>$part)(?:\.(?<minor>$part)(?:\.(?<patch>$part)" +
    "(?:-(?<pre>$pre(?:\.$pre)*))?" +
    '(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)?)?$'

    if ($Text -cnotmatch $pattern) {
        return $null
    }

    $major = if ($Matches.major -notin 'x', '*') {
        [int]$Matches.major
    }
    $minor = if ($Matches['minor'] -and $Matches.minor -notin 'x', '*') {
        [int]$Matches.minor
    }
    $patch = if ($Matches['patch'] -and $Matches.patch -notin 'x', '*') {
        [int]$Matches.patch
    }

    if (($null -eq $major -and $null -ne $minor) -or
        ($null -eq $minor -and $null -ne $patch) -or
        ($null -eq $patch -and $Matches['pre'])) {
        return $null
    }

    return [PartialVersion]@{
        Major = $major
        Minor = $minor
        Patch = $patch
        Pre = $Matches['pre']
    }
}

function Get-UpperBound {
    param([PartialVersion]$Version, [string]$Op)

    if ($null -eq $Version.Minor -or ($Op -eq '^' -and $Version.Major -gt 0)) {
        return [semver]::new(($Version.Major + 1), 0, 0, '0')
    }
    if ($Op -eq '^' -and $Version.Minor -eq 0 -and $null -ne $Version.Patch) {
        return [semver]::new(0, 0, ($Version.Patch + 1), '0')
    }

    return [semver]::new($Version.Major, ($Version.Minor + 1), 0, '0')
}

function ConvertTo-Comparator {
    param([string]$Token)

    $match = [regex]::Match($Token, '^(?<op>>=|<=|>|<|=|\^|~)?(?<ver>.+)$')
    $partial = ConvertFrom-PartialVersion $match.Groups['ver'].Value
    if ($null -eq $partial) {
        throw "invalid version specification: '$Token'"
    }

    $op = $match.Groups['op'].Value
    $low = $partial.ToSemVer()
    if ($null -eq $partial.Major) {
        if ($op -in '<', '>') {
            return [Comparator]::new('<', [semver]::new(0, 0, 0, '0'))
        }
        return [Comparator]::new('>=', $low)
    }

    if ($op -in '^', '~') {
        [Comparator]::new('>=', $low)
        [Comparator]::new('<', (Get-UpperBound $partial $op))
        return
    }

    if ($null -ne $partial.Patch) {
        if (-not $op) {
            $op = '='
        }
        return [Comparator]::new($op, $low)
    }

    switch ($op) {
        '>=' {
            [Comparator]::new('>=', $low)
        }
        '<=' {
            [Comparator]::new('<', (Get-UpperBound $partial))
        }
        '>' {
            $high = Get-UpperBound $partial
            [Comparator]::new('>=', [semver]::new($high.Major, $high.Minor, $high.Patch))
        }
        '<' {
            [Comparator]::new('<', [semver]::new($low.Major, $low.Minor, 0, '0'))
        }
        default {
            [Comparator]::new('>=', $low)
            [Comparator]::new('<', (Get-UpperBound $partial))
        }
    }
}

function ConvertTo-ComparatorSet {
    param([string]$Spec)

    $sets = [System.Collections.Generic.List[object]]::new()
    foreach ($clause in ($Spec -split '\|\|')) {
        $clause = $clause.Trim()

        if ($clause -cmatch '^(?<left>\S+)\s+-\s+(?<right>\S+)$') {
            $left = ConvertFrom-PartialVersion $Matches.left
            $right = ConvertFrom-PartialVersion $Matches.right
            if ($null -eq $left -or $null -eq $right) {
                throw "invalid hyphen range: '$clause'"
            }

            $sets.Add(@(
                    [Comparator]::new('>=', $left.ToSemVer())
                    if ($null -ne $right.Patch) {
                        [Comparator]::new('<=', $right.ToSemVer())
                    } elseif ($null -ne $right.Major) {
                        [Comparator]::new('<', (Get-UpperBound $right))
                    }
                ))
            continue
        }

        $clause = $clause -replace '(>=|<=|>|<|=|\^|~)\s+', '$1'
        $comparators = @(
            foreach ($token in ($clause -split '[\s,]+')) {
                if ($token) {
                    ConvertTo-Comparator $token
                }
            }
        )

        if ($comparators.Count -eq 0) {
            throw "invalid version range: '$Spec'"
        }
        $sets.Add($comparators)
    }

    return , $sets.ToArray()
}

function Test-VersionRange {
    param([semver]$Version, $Sets)

    foreach ($set in $Sets) {
        $matchesRange = $true
        $allowsPrerelease = -not $Version.PreReleaseLabel

        foreach ($comparator in $set) {
            $bound = $comparator.Version
            $cmp = $Version.CompareTo($bound)
            $matchesRange = switch ($comparator.Op) {
                '=' {
                    $cmp -eq 0
                }
                '>=' {
                    $cmp -ge 0
                }
                '<=' {
                    $cmp -le 0
                }
                '>' {
                    $cmp -gt 0
                }
                '<' {
                    $cmp -lt 0
                }
            }

            if (-not $matchesRange) {
                break
            }
            if ($bound.PreReleaseLabel -and
                $bound.Major -eq $Version.Major -and
                $bound.Minor -eq $Version.Minor -and
                $bound.Patch -eq $Version.Patch) {
                $allowsPrerelease = $true
            }
        }

        if ($matchesRange -and $allowsPrerelease) {
            return $true
        }
    }

    return $false
}

function Invoke-ReleaseRequest {
    param([string]$Uri, [switch]$AllowNotFound)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $data = Invoke-RestMethod -Uri $Uri -Headers $apiHeaders -ResponseHeadersVariable responseHeaders
            return [PSCustomObject]@{ Data = $data; Headers = $responseHeaders }
        } catch {
            $status = if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                [int]$_.Exception.Response.StatusCode
            }

            if ($AllowNotFound -and $status -eq 404) {
                return $null
            }
            if ($attempt -lt 3 -and ($null -eq $status -or $status -in 429, 500, 502, 503, 504)) {
                Start-Sleep -Seconds (2 * $attempt)
                continue
            }
            if ($status -eq 403) {
                $msg = "github api request failed with http 403 for '$Uri' (check the 'token' input and api rate limit)"
                throw [System.InvalidOperationException]::new($msg, $_.Exception)
            }
            throw
        }
    }
}

function Get-Release {
    $uri = "$ApiBase/releases?per_page=100"
    while ($uri) {
        $response = Invoke-ReleaseRequest $uri
        $response.Data
        $uri = if (($response.Headers['Link'] -join ',') -match '<([^>]+)>;\s*rel="next"') {
            $Matches[1]
        }
    }
}

function Find-Asset {
    param(
        [Parameter(Mandatory = $true)]
        $Release,
        [Parameter(Mandatory = $true)]
        $Platform
    )

    $exactName = "astra-$($Release.tag_name)-$($Platform.AssetLabel)"
    foreach ($asset in $Release.assets) {
        if ($asset.name -eq $exactName) {
            return $asset
        }
    }

    foreach ($asset in $Release.assets) {
        if ($asset.name -match $Platform.AssetRegex) {
            return $asset
        }
    }

    return $null
}

function Get-ToolCache {
    param([string]$Version, $Platform)

    $root = $env:RUNNER_TOOL_CACHE
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path $tempDir 'astra-tool-cache'
    }

    $versionDir = Join-Path -Path $root -ChildPath 'astra' -AdditionalChildPath $Version
    $dir = Join-Path $versionDir $Platform.Arch
    $marker = Join-Path $versionDir "$($Platform.Arch).complete"
    $exe = Join-Path $dir $Platform.ExeName

    $tag = if ((Test-Path -LiteralPath $marker -PathType Leaf) -and (Test-Path -LiteralPath $exe -PathType Leaf)) {
        [System.IO.File]::ReadAllText($marker)
    }

    return [PSCustomObject]@{
        Dir = $dir
        Marker = $marker
        Exe = $exe
        Tag = $tag
    }
}

function Save-Asset {
    param([string]$Uri, [string]$OutFile)

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -UserAgent 'korarei-setup-astra' -OutFile $OutFile
            return
        } catch {
            if ($attempt -eq 3) {
                throw
            }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Install-Astra {
    param($Release, $Platform, $Cache)

    $asset = Find-Asset $Release $Platform
    if ($null -eq $asset) {
        throw "release '$($Release.tag_name)' does not contain an asset matching '$($Platform.AssetLabel)'"
    }

    $workDir = Join-Path $tempDir ("setup-astra-" + [guid]::NewGuid().ToString('N'))
    $extractDir = Join-Path $workDir 'extract'
    $archive = Join-Path $workDir "astra.$($Platform.ArchiveType)"

    try {
        $null = [System.IO.Directory]::CreateDirectory($extractDir)
        Write-Information -MessageData "Downloading Astra $($Release.tag_name) ($($asset.name))"
        Save-Asset $asset.browser_download_url $archive

        if ($Platform.ArchiveType -eq 'zip') {
            Expand-Archive -LiteralPath $archive -DestinationPath $extractDir
        } else {
            & tar -xzf $archive -C $extractDir
            if ($LASTEXITCODE -ne 0) {
                throw "failed to extract '$($asset.name)' with tar (exit code: $LASTEXITCODE)"
            }
        }

        $srcDir = $extractDir
        if (-not (Test-Path -LiteralPath (Join-Path $extractDir $Platform.ExeName) -PathType Leaf)) {
            $exe = Get-ChildItem -LiteralPath $extractDir -Filter $Platform.ExeName -Recurse -File |
                Select-Object -First 1
            if ($null -eq $exe) {
                throw "executable '$($Platform.ExeName)' was not found in archive '$($asset.name)'"
            }
            $srcDir = $exe.DirectoryName
        }

        if (Test-Path -LiteralPath $Cache.Marker) {
            Remove-Item -LiteralPath $Cache.Marker -Force
        }

        if (Test-Path -LiteralPath $Cache.Dir) {
            Remove-Item -LiteralPath $Cache.Dir -Recurse -Force
        }

        $null = [System.IO.Directory]::CreateDirectory($Cache.Dir)
        $items = (Get-ChildItem -LiteralPath $srcDir -Force).FullName
        Copy-Item -LiteralPath $items -Destination $Cache.Dir -Recurse -Force

        if ($Platform.OS -eq 'Linux') {
            & chmod +x $Cache.Exe
            if ($LASTEXITCODE -ne 0) {
                throw "failed to set executable permission on '$($Cache.Exe)' (exit code: $LASTEXITCODE)"
            }
        }
    } finally {
        if (Test-Path -LiteralPath $workDir) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Continue
        }
    }
}

function Find-Release {
    param([string]$Spec, $Platform)

    $sets = ConvertTo-ComparatorSet $Spec
    Write-Information -MessageData "Resolving version range '$Spec' from $Repo"

    $bestRelease = $null
    $bestVersion = $null
    $missingAssets = [System.Collections.Generic.List[string]]::new()
    $hasBelowMin = $false

    foreach ($release in (Get-Release)) {
        if ($release.draft) {
            continue
        }

        $version = ConvertFrom-SemVer $release.tag_name
        if ($null -eq $version -or ($release.prerelease -and -not $version.PreReleaseLabel) -or
            -not (Test-VersionRange $version $sets)) {
            continue
        }

        if ($version -lt $minVersion) {
            $hasBelowMin = $true
            continue
        }

        if ($null -eq (Find-Asset $release $Platform)) {
            $missingAssets.Add($release.tag_name)
            continue
        }

        if ($null -eq $bestRelease -or $version -gt $bestVersion) {
            $bestRelease = $release
            $bestVersion = $version
        }
    }

    if ($null -ne $bestRelease) {
        return [PSCustomObject]@{ Release = $bestRelease; Version = $bestVersion }
    }

    if ($missingAssets.Count -gt 0) {
        $tags = $missingAssets -join ', '
        throw "releases matching '$Spec' ($tags) do not provide '$($Platform.AssetLabel)'"
    }

    if ($hasBelowMin) {
        throw "no supported release matching '$Spec' was found (setup-astra requires astra v0.7.0 or later)"
    }

    throw "no release matching '$Spec' was found in $Repo"
}

$versionInput = if ([string]::IsNullOrWhiteSpace($env:ASTRA_INPUT_VERSION)) {
    'latest'
} else {
    $env:ASTRA_INPUT_VERSION.Trim()
}

$platform = Get-Platform
$minVersion = [semver]'0.7.0'
$tempDir = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetTempPath()
} else {
    $env:RUNNER_TEMP
}

$apiHeaders = @{
    'Accept' = 'application/vnd.github+json'
    'User-Agent' = 'korarei-setup-astra'
    'X-GitHub-Api-Version' = '2022-11-28'
}
if (-not [string]::IsNullOrWhiteSpace($env:ASTRA_INPUT_TOKEN)) {
    $apiHeaders['Authorization'] = "Bearer $($env:ASTRA_INPUT_TOKEN)"
}

$release = $null
$cache = $null
$version = ConvertFrom-SemVer ($versionInput -creplace '^=', '')

if ($versionInput -eq 'latest') {
    Write-Information -MessageData "Resolving latest release from $Repo"
    $release = (Invoke-ReleaseRequest "$ApiBase/releases/latest").Data
    $version = ConvertFrom-SemVer $release.tag_name
    if ($null -eq $version) {
        throw "latest release tag '$($release.tag_name)' is not a valid semver version"
    }
    if ($version -lt $minVersion) {
        throw "latest release '$($release.tag_name)' is below the minimum supported version (v0.7.0)"
    }
} elseif ($null -ne $version) {
    if ($version -lt $minVersion) {
        throw "astra version '$versionInput' is below the minimum supported version (v0.7.0)"
    }
    $cache = Get-ToolCache $version $platform
    $tags = "v$version", $version.ToString()

    if ($cache.Tag -cnotin $tags) {
        Write-Information -MessageData "Resolving release '$($tags[0])' from $Repo"
        foreach ($candidate in $tags) {
            $release = (Invoke-ReleaseRequest "$ApiBase/releases/tags/$candidate" -AllowNotFound)?.Data
            if ($null -ne $release) {
                break
            }
        }

        if ($null -eq $release) {
            throw "release '$versionInput' was not found in $Repo"
        }
        if ($release.draft) {
            throw "release '$($release.tag_name)' is a draft and cannot be installed"
        }
    }
} else {
    $match = Find-Release $versionInput $platform
    $release = $match.Release
    $version = $match.Version
}

$cache ??= (Get-ToolCache $version $platform)
$tag = if ($null -eq $release) {
    $cache.Tag
} else {
    $release.tag_name
}
$isCacheHit = $cache.Tag -ceq $tag

if ($isCacheHit) {
    Write-Information -MessageData "Found Astra $tag ($($platform.Arch)) in tool cache: $($cache.Dir)"
} else {
    Install-Astra -Release $release -Platform $platform -Cache $cache
}

try {
    $versionOutput = & $cache.Exe --version
    if ($LASTEXITCODE -ne 0) {
        throw "failed to verify astra executable at '$($cache.Exe)' (exit code: $LASTEXITCODE)"
    }
} catch {
    if ($isCacheHit) {
        Remove-Item -LiteralPath $cache.Marker -Force -ErrorAction Continue
    }
    throw
}

Write-Information -MessageData "Verified: $versionOutput"

if (-not $isCacheHit) {
    [System.IO.File]::WriteAllText($cache.Marker, $tag)
    Write-Information -MessageData "Installed Astra $tag to $($cache.Dir)"
}

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
    [System.IO.File]::AppendAllText($env:GITHUB_PATH, "$($cache.Dir)`n")
}

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    $lines = "version=$version", "tag=$tag", "path=$($cache.Dir)" -join "`n"
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$lines`n")
}
