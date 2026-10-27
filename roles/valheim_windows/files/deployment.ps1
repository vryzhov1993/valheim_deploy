Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Get-DeploymentPath([string]$Root, [string]$Relative) {
    if ($Root -notmatch '^[A-Za-z]:\\' -or $Root -match '(^|[\\/])\.\.?([\\/]|$)') {
        throw 'Use an absolute local Windows directory without dot segments.'
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($base.Length -le 3) { throw 'A drive root is not a deployment directory.' }
    $full = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Path escapes the deployment directory.'
    }
    $parent = [IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($full))
    while ($parent.FullName.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Deployment path traverses an unexpected junction.'
        }
        $parent = $parent.Parent
    }
    return $full
}

function Initialize-Deployment([string]$Root) {
    $marker = Get-DeploymentPath $Root '.valheim-windows-managed'
    if (Test-Path -LiteralPath $Root) {
        $item = Get-Item -LiteralPath $Root -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Deployment root must be a real directory.'
        }
        if (-not (Test-Path -LiteralPath $marker) -and @(Get-ChildItem -LiteralPath $Root -Force).Count) {
            throw 'Use an empty directory; existing installations are not adopted automatically.'
        }
        foreach ($name in @('config', 'server', 'service', 'downloads', 'steamcmd', 'logs')) {
            $path = Get-DeploymentPath $Root $name
            if ((Test-Path -LiteralPath $path) -and
                ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Unexpected junction in deployment root: $name"
            }
        }
    }
    if (Test-Path -LiteralPath $marker) {
        if ([IO.File]::ReadAllText($marker) -ne 'valheim-windows-v1') { throw 'Unknown deployment marker.' }
        return $false
    }
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    [IO.File]::WriteAllText($marker, 'valheim-windows-v1')
    return $true
}

function Import-WorldBundle([string]$Root, [string]$Archive, [string]$World) {
    if ($World -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid world name.' }
    $config = Get-DeploymentPath $Root 'config'
    $marker = Get-DeploymentPath $Root 'config\.valheim-bundle.json'
    if (Test-Path -LiteralPath $marker) {
        $installed = [IO.File]::ReadAllText($marker) | ConvertFrom-Json
        if ($installed.schema -ne 1 -or $installed.world -cne $World -or
            -not (Test-Path -LiteralPath (Join-Path $config "worlds_local\$World") -PathType Container)) {
            throw 'Imported world identity does not match the requested world.'
        }
        return $false
    }
    if ((Test-Path -LiteralPath $config) -and @(Get-ChildItem -LiteralPath $config -Force).Count) {
        throw 'Existing configuration has no import marker; overwrite refused.'
    }
    $stageName = '.import-' + [guid]::NewGuid().ToString('N')
    $stage = Get-DeploymentPath $Root $stageName
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
        try {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $zip.Entries) {
                $name = $entry.FullName.TrimEnd('/')
                if ($name -match '[\\:\x00-\x1f<>"|?*]' -or $name.StartsWith('/') -or
                    @($name.Split('/') | Where-Object { $_ -in @('', '.', '..') -or $_ -match '[. ]$' -or
                        $_ -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$' }).Count -or
                    (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or
                    -not $names.Add($name)) { throw 'Unsafe or duplicate ZIP entry.' }
                Get-DeploymentPath $stage ($name.Replace('/', '\')) | Out-Null
                if ($name -ne 'config' -and -not $name.StartsWith('config/', [StringComparison]::Ordinal)) {
                    throw 'Archive must contain only config/.'
                }
            }
        } finally { $zip.Dispose() }
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $stage)
        $manifestPath = Get-DeploymentPath $stage 'config\.valheim-bundle.json'
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($manifest.schema -ne 1 -or $manifest.world -cne $World) { throw 'Bundle world mismatch.' }
        $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $manifest.files.PSObject.Properties) {
            $relative = $property.Name
            if (-not ($relative.StartsWith("worlds_local/$World/", [StringComparison]::Ordinal) -or
                $relative.StartsWith('bepinex/', [StringComparison]::Ordinal) -or
                $relative -cin @('adminlist.txt', 'bannedlist.txt', 'permittedlist.txt'))) {
                throw 'Unexpected file in manifest.'
            }
            $name = 'config/' + $relative
            if (-not $expected.Add($name)) { throw 'Duplicate manifest filename.' }
            $file = Get-DeploymentPath $stage ($name.Replace('/', '\'))
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
                (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $property.Value) {
                throw 'Bundle file checksum mismatch.'
            }
        }
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $stage 'config') -File -Recurse -Force |
            Where-Object { $_.FullName -ne $manifestPath })
        if ($actual.Count -ne $expected.Count) { throw 'Archive contains unlisted files.' }
        $worldPath = Get-DeploymentPath $stage "config\worlds_local\$World"
        $generations = @(Get-ChildItem -LiteralPath $worldPath -Filter '_main.*.ok' -File)
        if (-not $generations.Count -or -not @(Get-ChildItem -LiteralPath $worldPath -Filter '*.chunk' -File).Count) {
            throw 'No committed world generation or chunk files.'
        }
        foreach ($generation in $generations) {
            $base = $generation.FullName.Substring(0, $generation.FullName.Length - 3)
            foreach ($suffix in @('.fwl2', '.db2', '.chunks')) {
                if (-not (Test-Path -LiteralPath ($base + $suffix) -PathType Leaf)) { throw 'Incomplete save generation.' }
            }
        }
        # Only an empty destination may be removed before the atomic directory move.
        if (Test-Path -LiteralPath $config) { [IO.Directory]::Delete($config, $false) }
        [IO.Directory]::Move((Join-Path $stage 'config'), $config)
        return $true
    } finally {
        # The validated, unique staging directory is always inside this deployment.
        if ($stage -ne (Get-DeploymentPath $Root $stageName)) { throw 'Invalid staging cleanup path.' }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

function Install-BepInEx([string]$Root, [string]$Source, [bool]$ServiceRunning = $false) {
    $changed = $false
    $files = @('winhttp.dll', 'doorstop_config.ini', '.doorstop_version')
    $core = Join-Path $Source 'BepInEx\core'
    $files += @(Get-ChildItem -LiteralPath $core -File -Recurse | ForEach-Object {
        $_.FullName.Substring($Source.TrimEnd('\').Length + 1)
    })
    foreach ($relative in $files) {
        $src = Join-Path $Source $relative
        $dest = Get-DeploymentPath $Root ('server\' + $relative)
        if (-not (Test-Path -LiteralPath $dest) -or
            (Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $dest).Hash) {
            if ($ServiceRunning) { throw 'Stop the service before updating BepInEx.' }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $dest)) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dest
            $changed = $true
        }
    }
    foreach ($name in @('config', 'plugins', 'patchers')) {
        $relative = if ($name -eq 'config') { 'config\bepinex' } else { 'config\bepinex\' + $name }
        $target = Get-DeploymentPath $Root $relative
        if ((Test-Path -LiteralPath $target) -and
            ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'BepInEx source must be a real directory.'
        }
        [IO.Directory]::CreateDirectory($target) | Out-Null
        $link = Get-DeploymentPath $Root ('server\BepInEx\' + $name)
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                if ($item.LinkType -ne 'Junction' -or
                    [IO.Path]::GetFullPath(@($item.Target)[0]).TrimEnd('\') -ine $target) {
                    throw 'Unexpected BepInEx junction target.'
                }
                continue
            }
            if (-not $item.PSIsContainer -or @(Get-ChildItem -LiteralPath $link -Force).Count) {
                throw 'Existing BepInEx data will not be overwritten.'
            }
            [IO.Directory]::Delete($link, $false)
        }
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        $changed = $true
    }
    return $changed
}
