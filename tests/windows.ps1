param([switch]$TestService)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\..\roles\valheim_windows\files\deployment.ps1"

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$MessagePattern) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $MessagePattern) { throw }
        return
    }
    throw 'Expected a validation failure.'
}
function Write-TestBundle([string]$Path, [hashtable]$Files, [bool]$BadHash = $false) {
    $hashes = @{}
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Files.Keys) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Files[$name])
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hashes[$name] = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
            $stream = $zip.CreateEntry('config/' + $name).Open()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
        if ($BadHash) { $hashes['worlds_local/purgatory/1_1.chunk'] = '0' * 64 }
        $manifest = @{ schema = 1; world = 'purgatory'; files = $hashes } | ConvertTo-Json -Depth 5
        $bytes = [Text.Encoding]::UTF8.GetBytes($manifest)
        $stream = $zip.CreateEntry('config/.valheim-bundle.json').Open()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.local'))
$testRoot = Join-Path $workspace ('windows-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$files = @{
    'worlds_local/purgatory/_main.1.ok' = ''
    'worlds_local/purgatory/_main.1.fwl2' = 'header'
    'worlds_local/purgatory/_main.1.db2' = 'data'
    'worlds_local/purgatory/_main.1.chunks' = 'index'
    'worlds_local/purgatory/1_1.chunk' = 'initial-progress'
    'bepinex/example.cfg' = 'original-config'
    'bepinex/plugins/example.dll' = 'plugin'
    'adminlist.txt' = 'identity'
}
$archive = Join-Path $testRoot 'fixture.zip'
Write-TestBundle $archive $files
$server = Join-Path $testRoot 'server with spaces'
Assert-True (Initialize-Deployment $server) 'First initialization must change state.'
Assert-True (-not (Initialize-Deployment $server)) 'Initialization must be idempotent.'
Assert-True (Import-WorldBundle $server $archive 'purgatory') 'First import must change state.'
$chunk = Join-Path $server 'config\worlds_local\purgatory\1_1.chunk'
[IO.File]::WriteAllText($chunk, 'new-progress')
Assert-True (-not (Import-WorldBundle $server '' 'purgatory')) 'Repeat import must be skipped.'
Assert-True ([IO.File]::ReadAllText($chunk) -eq 'new-progress') 'Repeat import overwrote progress.'
Assert-Throws { Import-WorldBundle $server '' 'wrong-world' } 'identity'
Assert-Throws { Initialize-Deployment ([IO.Path]::GetPathRoot($server)) } 'drive root'

$foreign = Join-Path $testRoot 'foreign'
Initialize-Deployment $foreign | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $foreign 'config')) | Out-Null
[IO.File]::WriteAllText((Join-Path $foreign 'config\keep.txt'), 'keep')
Assert-Throws { Import-WorldBundle $foreign $archive 'purgatory' } 'overwrite refused'

$bad = Join-Path $testRoot 'bad-checksum.zip'
Write-TestBundle $bad $files $true
$badServer = Join-Path $testRoot 'bad-server'
Initialize-Deployment $badServer | Out-Null
Assert-Throws { Import-WorldBundle $badServer $bad 'purgatory' } 'checksum mismatch'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $badServer 'config'))) 'Failed import must not publish config.'
Assert-True (@(Get-ChildItem -LiteralPath $badServer -Filter '.import-*' -Force).Count -eq 0) 'Plaintext staging was not removed.'

$unsafe = Join-Path $testRoot 'unsafe.zip'
$files['../escape.txt'] = 'escape'
Write-TestBundle $unsafe $files
Assert-Throws { Import-WorldBundle $badServer $unsafe 'purgatory' } 'Unsafe'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $badServer 'escape.txt'))) 'ZIP path traversal escaped staging.'

$source = Join-Path $testRoot 'bepinex-source'
[IO.Directory]::CreateDirectory((Join-Path $source 'BepInEx\core')) | Out-Null
foreach ($name in @('winhttp.dll', 'doorstop_config.ini', '.doorstop_version', 'BepInEx\core\BepInEx.dll')) {
    [IO.File]::WriteAllText((Join-Path $source $name), 'fixture')
}
Assert-True (Install-BepInEx $server $source) 'BepInEx must be installed once.'
Assert-True (-not (Install-BepInEx $server $source)) 'BepInEx setup must be idempotent.'
Assert-True ((Get-Item -LiteralPath (Join-Path $server 'server\BepInEx\plugins')).LinkType -eq 'Junction') 'Plugins must use the imported directory.'
[IO.File]::WriteAllText((Join-Path $source 'winhttp.dll'), 'updated-fixture')
Assert-Throws { Install-BepInEx $server $source $true } 'Stop the service'
Write-Host 'PASS: Windows import, progress preservation, ZIP safety, checksum validation and BepInEx junctions.'

if ($TestService) {
    $wrapper = Join-Path $testRoot 'service-test.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe' -OutFile $wrapper
    Assert-True ((Get-FileHash -LiteralPath $wrapper -Algorithm SHA256).Hash -eq '05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA') 'WinSW checksum mismatch.'
    $exe = Join-Path $testRoot 'fake-server.exe'
    Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public class FakeValheim {
    public static void Main(string[] args) {
        var stop = new ManualResetEvent(false);
        Console.CancelKeyPress += (s,e) => { e.Cancel=true; File.WriteAllText(args[0]+".stopped", "saved"); stop.Set(); };
        File.WriteAllText(args[0]+".ready", "ready");
        stop.WaitOne();
    }
}
'@
    $name = 'ValheimSmoke-' + [guid]::NewGuid().ToString('N')
    $signal = Join-Path $testRoot 'fake-signal'
    $xml = "<service><id>$name</id><name>$name</name><description>Valheim service lifecycle test</description><executable>$exe</executable><arguments>$signal</arguments><startmode>Manual</startmode><stoptimeout>10 sec</stoptimeout><log mode=`"append`"/></service>"
    [IO.File]::WriteAllText((Join-Path $testRoot 'service-test.xml'), $xml)
    try {
        & $wrapper install
        Assert-True ($LASTEXITCODE -eq 0) 'WinSW install failed.'
        Assert-True ((Get-Service -Name $name).Status -eq 'Stopped') 'Install must not launch the service.'
        Assert-True ((Get-CimInstance Win32_Service -Filter "Name='$name'").StartMode -eq 'Manual') 'Service must not start at boot during preparation.'
        Start-Service -Name $name
        $deadline = [datetime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath ($signal + '.ready')) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        Assert-True (Test-Path -LiteralPath ($signal + '.ready')) 'Fixture server did not start.'
        Stop-Service -Name $name
        Assert-True (Test-Path -LiteralPath ($signal + '.stopped')) 'Graceful CTRL+C shutdown did not run.'
        Write-Host 'PASS: WinSW installs without starting and stops a synthetic console server gracefully.'
    } finally {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
            Stop-Service -Name $name -ErrorAction SilentlyContinue
            & $wrapper uninstall
        }
    }
}
