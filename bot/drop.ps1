# Stratlab pack drop bot. Reads the new messages in a Discord channel; every valid .stratlab attachment is
# published to the catalog (the file as an asset of the rolling "packs" release, an entry in catalog.json)
# and the message gets a reaction and a reply. "remove <pack name>" by the pack's publisher takes it down.
#   bot\drop.ps1                    in GitHub Actions: env DISCORD_TOKEN, DISCORD_CHANNEL, GH_TOKEN
#   bot\drop.ps1 -Local <folder>    test run: every .stratlab in the folder counts as a posted message;
#                                   nothing is sent to Discord or GitHub, the files land in work\
# Windows PowerShell 5.1 (the same engine the app runs on, so the checks behave the same). ASCII only in this
# file: 5.1 reads scripts without a byte-order mark as the system code page.
param([string]$Local)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression, System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $root 'catalog.json'
$statePath = Join-Path $PSScriptRoot 'state.json'
$work = Join-Path $root 'work'; New-Item -ItemType Directory -Force $work | Out-Null
$repo = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'TitanJammer/stratlab-packs' }
$APP_REPO = 'TitanJammer/Stratlab'
$RELEASE = 'packs'
$UA = "Stratlab-packs-bot (https://github.com/$repo)"
$MAX_PACK = 25MB; $MAX_PIC = 8MB; $MAX_JSON = 4MB; $MAX_ENTRIES = 600; $MAX_STRATS = 200; $MAX_PACKS = 500
$TYPES = @('post-plant', 'entry', 'smoke', 'one-way', 'flash', 'recon', 'setup', 'deny')
$OK = [char]::ConvertFromUtf32(0x2705); $NO = [char]::ConvertFromUtf32(0x274C)   # the reactions: check mark, cross mark
$OK_URL = '%E2%9C%85'; $NO_URL = '%E2%9D%8C'

function Read-Json([string]$p) { Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-Json([string]$p, $obj) { [IO.File]::WriteAllText($p, ($obj | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false)) }
function Clip($v, [int]$len) { $t = (([string]$v).Trim() -replace '[\x00-\x1f]', ''); if ($t.Length -gt $len) { $t.Substring(0, $len).Trim() } else { $t } }
function Sha256([byte[]]$b) { $h = [Security.Cryptography.SHA256]::Create(); try { ([BitConverter]::ToString($h.ComputeHash($b)) -replace '-', '').ToLower() } finally { $h.Dispose() } }
function Owner-Of([string]$userId) { (Sha256 ([Text.Encoding]::UTF8.GetBytes("stratlab:$userId"))).Substring(0, 16) }   # who may update a pack: a hash, not the id itself

# the game data the app ships (agents and maps a pack may use): the app repository's copy, else the one here
function Get-Game {
    try {
        $g = (Invoke-WebRequest "https://raw.githubusercontent.com/$APP_REPO/main/data/game.json" -Headers @{ 'User-Agent' = $UA } -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
        if ($g.agents -and $g.maps) { return $g }
    } catch {}
    Read-Json (Join-Path $PSScriptRoot 'game.json')
}

# open and check a pack the way the app does on import; returns what the catalog records about it
function Test-Pack([byte[]]$bytes, $game) {
    if ($bytes.Length -gt $MAX_PACK) { throw "the pack is over $([int]($MAX_PACK / 1MB)) MB" }
    try { $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream (, $bytes)), [IO.Compression.ZipArchiveMode]::Read) } catch { throw 'the file is not a .stratlab pack (not a valid zip)' }
    $files = @{}
    try {
        if ($zip.Entries.Count -gt $MAX_ENTRIES) { throw 'the pack has too many files' }
        foreach ($en in $zip.Entries) {
            $nm = $en.FullName -replace '\\', '/'
            if ($nm.EndsWith('/')) { continue }
            $cap = if ($nm -eq 'manifest.json' -or $nm -eq 'strats.json') { $MAX_JSON }
                   elseif ($nm -match '^pics/[A-Za-z0-9_-]{1,40}\.(jpg|jpeg|png)$') { $MAX_PIC }
                   else { throw "unexpected file in the pack: $nm" }
            $st = $en.Open(); $ms = New-Object IO.MemoryStream; $chunk = New-Object byte[] 65536
            try { while (($r = $st.Read($chunk, 0, $chunk.Length)) -gt 0) { $ms.Write($chunk, 0, $r); if ($ms.Length -gt $cap) { throw "a file in the pack is too big: $nm" } } } finally { $st.Dispose() }
            $files[$nm] = $ms.ToArray()
        }
    } finally { $zip.Dispose() }
    if (-not $files['manifest.json'] -or -not $files['strats.json']) { throw 'the file is not a .stratlab pack (manifest or strats missing)' }
    $man = [Text.Encoding]::UTF8.GetString($files['manifest.json']) | ConvertFrom-Json
    if (@('stratlab', 'lineuplab') -notcontains [string]$man.format) { throw 'the file is not a .stratlab pack' }
    $id = ([string]$man.id) -replace '[^A-Za-z0-9-]', ''; if (-not $id -or $id.Length -gt 60) { throw 'the pack has no usable id' }
    $name = Clip $man.name 60; if (-not $name) { throw 'the pack has no name (set one in the pack builder)' }
    $raw = @([Text.Encoding]::UTF8.GetString($files['strats.json']) | ConvertFrom-Json | ForEach-Object { $_ })
    if (-not $raw.Count) { throw 'the pack is empty' }
    if ($raw.Count -gt $MAX_STRATS) { throw "the pack has too many strats (over $MAX_STRATS)" }
    $agents = @(); $maps = @(); $types = @(); $checked = @{}
    foreach ($s in $raw) {
        $agent = Clip $s.agent 30; $map = Clip $s.map 30
        if (-not ($game.agents | Where-Object { $_.name -eq $agent })) { throw "unknown agent: '$agent'" }
        if (@($game.maps) -notcontains $map) { throw "unknown map: '$map'" }
        $type = ([string]$s.type).ToLower(); if ($TYPES -notcontains $type) { $type = 'post-plant' }
        if (([string]$s.site).ToUpper() -notmatch '^[ABC]$') { throw "bad site: '$($s.site)'" }
        $steps = @($s.steps); if ($steps.Count -lt 1 -or $steps.Count -gt 5) { throw "a strat has $($steps.Count) steps (1 to 5 allowed)" }
        foreach ($stp in $steps) {
            $srcs = @($stp.src | ForEach-Object { [string]$_ })
            if (-not $srcs.Count -or $srcs.Count -gt 12) { throw 'a step has no pictures, or too many' }
            foreach ($src in $srcs) {
                if (-not $files.ContainsKey($src)) { throw "a picture is missing from the pack: $src" }
                if (-not $checked.ContainsKey($src)) {
                    try { $im = [System.Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $files[$src]))); $good = $im.Width -le 8000 -and $im.Height -le 8000; $im.Dispose() } catch { $good = $false }
                    if (-not $good) { throw "not a valid picture: $src" }
                    $checked[$src] = $true
                }
            }
        }
        if ($agents -notcontains $agent) { $agents += $agent }
        if ($maps -notcontains $map) { $maps += $map }
        if ($types -notcontains $type) { $types += $type }
    }
    @{ id = $id; name = $name; description = (Clip $man.description 500); author = (Clip $man.author 40); stamp = (Clip $man.created 30)
       strats = $raw.Count; agents = $agents; maps = $maps; types = $types; pictures = $checked.Count }
}

# --- GitHub: the pack files live as assets of one rolling release, so the repository stays small ---------
function Gh([string[]]$a) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & gh @a 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    @{ code = $code; out = ($out -join "`n") }
}
function Ensure-Release {
    if ((Gh @('release', 'view', $RELEASE, '-R', $repo)).code -eq 0) { return }
    $r = Gh @('release', 'create', $RELEASE, '-R', $repo, '--title', 'Pack files', '--notes', 'The .stratlab files listed in catalog.json. Install them from Packs > Browse in Stratlab.', '--latest=false')
    if ($r.code -ne 0) { throw "could not create the packs release: $($r.out)" }
}
function Upload-Asset([string]$file) {
    Ensure-Release
    $r = Gh @('release', 'upload', $RELEASE, $file, '-R', $repo, '--clobber')
    if ($r.code -ne 0) { throw "upload failed: $($r.out)" }
}
function Delete-Asset([string]$name) { Gh @('release', 'delete-asset', $RELEASE, $name, '-R', $repo, '-y') | Out-Null }

# --- the catalog -------------------------------------------------------------------------------------
function Read-Catalog {
    $c = if (Test-Path $catalogPath) { Read-Json $catalogPath } else { $null }
    $list = if ($c -and $c.packs) { @($c.packs | ForEach-Object { $_ } | Where-Object { $_ -and $_.id }) } else { @() }
    @{ packs = [Collections.ArrayList]@($list) }
}
function Write-Catalog($cat) {
    $o = [ordered]@{ format = 'stratlab-catalog'; version = 1; updated = (Get-Date).ToUniversalTime().ToString('s') + 'Z' }
    $o['packs'] = [object[]]@($cat.packs | Sort-Object { [string]$_.updated } -Descending)
    Write-Json $catalogPath $o
}
function Find-Pack($cat, [string]$key) {
    $k = $key.Trim()
    $hit = @($cat.packs | Where-Object { $_.id -eq $k }); if ($hit.Count) { return $hit[0] }
    $hit = @($cat.packs | Where-Object { [string]$_.name -eq $k }); if ($hit.Count -eq 1) { return $hit[0] }
    $null
}
function Publish-Pack($info, [byte[]]$bytes, $poster, $cat) {
    $old = Find-Pack $cat $info.id
    if ($old -and $old.owner -ne $poster.owner) { throw "'$($old.name)' was published by someone else; export your strats as a new pack instead" }
    if (-not $old -and $cat.packs.Count -ge $MAX_PACKS) { throw 'the catalog is full for now' }
    $file = Join-Path $work "$($info.id).stratlab"; [IO.File]::WriteAllBytes($file, $bytes)
    if (-not $Local) { Upload-Asset $file }
    $now = (Get-Date).ToUniversalTime().ToString('s') + 'Z'
    $e = [ordered]@{ id = $info.id; name = $info.name; description = $info.description; author = $info.author; strats = $info.strats }
    $e['agents'] = [object[]]$info.agents; $e['maps'] = [object[]]$info.maps; $e['types'] = [object[]]$info.types
    $e['size'] = $bytes.Length; $e['sha256'] = Sha256 $bytes; $e['stamp'] = $info.stamp
    $e['published'] = $(if ($old -and $old.published) { [string]$old.published } else { $now }); $e['updated'] = $now
    $e['publisher'] = $poster.name; $e['owner'] = $poster.owner
    $e['file'] = "https://github.com/$repo/releases/download/$RELEASE/$($info.id).stratlab"
    if ($old) { $cat.packs.Remove($old) }
    [void]$cat.packs.Add([pscustomobject]$e)
    @{ updated = [bool]$old }
}
function Remove-Pack($cat, [string]$key, $poster) {
    $p = Find-Pack $cat $key
    if (-not $p) { throw "no pack called '$key' is in the catalog" }
    if ($p.owner -ne $poster.owner) { throw "'$($p.name)' was published by someone else" }
    if (-not $Local) { Delete-Asset "$($p.id).stratlab" }
    $cat.packs.Remove($p)
    [string]$p.name
}

# --- Discord ------------------------------------------------------------------------------------------
$D = 'https://discord.com/api/v10'
function Discord([string]$method, [string]$path, $body) {
    $h = @{ Authorization = "Bot $env:DISCORD_TOKEN"; 'User-Agent' = $UA }
    for ($try = 0; $try -lt 4; $try++) {
        try {
            if ($null -ne $body) { return Invoke-RestMethod "$D$path" -Method $method -Headers $h -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 6 -Compress))) -TimeoutSec 30 }
            return Invoke-RestMethod "$D$path" -Method $method -Headers $h -TimeoutSec 30
        } catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -eq 429 -and $try -lt 3) { Start-Sleep -Seconds 4; continue }
            throw
        }
    }
}
function Get-NewMessages([string]$channel, [string]$after) {
    $all = @(); $cursor = $after
    while ($true) {
        $q = if ($cursor) { "?limit=100&after=$cursor" } else { '?limit=50' }   # first ever run: the last 50 messages
        $page = @(Discord 'Get' "/channels/$channel/messages$q" | ForEach-Object { $_ })
        if (-not $page.Count) { break }
        $all += $page
        if (-not $cursor -or $page.Count -lt 100) { break }
        $cursor = [string]($page | Sort-Object { [uint64]$_.id } | Select-Object -Last 1).id
    }
    $all | Sort-Object { [uint64]$_.id }
}
function Handled($m) { foreach ($r in @($m.reactions)) { if ($r.me -and (@($OK, $NO) -contains [string]$r.emoji.name)) { return $true } }; $false }
function React($m, [string]$emojiUrl) { if ($Local) { return }; Discord 'Put' "/channels/$($m.channel_id)/messages/$($m.id)/reactions/$emojiUrl/@me" | Out-Null; Start-Sleep -Milliseconds 400 }
function Reply($m, [string]$text) {
    Write-Host "  -> $text"
    if ($Local) { return }
    Discord 'Post' "/channels/$($m.channel_id)/messages" @{ content = $text; message_reference = @{ message_id = $m.id; fail_if_not_exists = $false }; allowed_mentions = @{ parse = @() } } | Out-Null
    Start-Sleep -Milliseconds 400
}
function Poster-Of($m) {
    $nm = if ($m.author.global_name) { [string]$m.author.global_name } else { [string]$m.author.username }
    @{ name = (Clip $nm 40); owner = (Owner-Of ([string]$m.author.id)) }
}

# --- the run -------------------------------------------------------------------------------------------
$game = Get-Game
$cat = Read-Catalog
$changed = $false
if ($Local) {
    $msgs = @(Get-ChildItem $Local -Filter '*.stratlab' | ForEach-Object {
        @{ id = [string](Get-Date $_.LastWriteTime -UFormat %s); channel_id = 'local'; content = ''; author = @{ id = 'local'; username = 'local'; global_name = 'Local test' }
           attachments = @(@{ filename = $_.Name; size = $_.Length; url = $_.FullName }); reactions = @() } })
    $cmds = Join-Path $Local 'commands.txt'   # optional: one "remove <name>" per line, to test removals
    if (Test-Path $cmds) { foreach ($line in (Get-Content $cmds)) { if ($line.Trim()) { $msgs += @{ id = '0'; channel_id = 'local'; content = $line; author = @{ id = 'local'; username = 'local' }; attachments = @(); reactions = @() } } } }
} else {
    if (-not $env:DISCORD_TOKEN -or -not $env:DISCORD_CHANNEL) { throw 'DISCORD_TOKEN and DISCORD_CHANNEL must be set' }
    $state = if (Test-Path $statePath) { Read-Json $statePath } else { $null }
    $after = if ($state -and $state.lastMessageId) { [string]$state.lastMessageId } else { '' }
    $msgs = @(Get-NewMessages $env:DISCORD_CHANNEL $after)
}
Write-Host "$($msgs.Count) message(s) to look at; $($cat.packs.Count) pack(s) in the catalog"
$last = ''
foreach ($m in $msgs) {
    if ($m.id -and -not $Local -and (-not $last -or [uint64]$m.id -gt [uint64]$last)) { $last = [string]$m.id }
    if ($m.author.bot -or (Handled $m)) { continue }
    $poster = Poster-Of $m
    $att = @($m.attachments | Where-Object { [string]$_.filename -match '\.(stratlab|lineuplab)$' })
    try {
        if ($att.Count) {
            $a = $att[0]
            Write-Host "pack '$($a.filename)' from $($poster.name)"
            if ([long]$a.size -gt $MAX_PACK) { throw "the pack is over $([int]($MAX_PACK / 1MB)) MB" }
            $bytes = if ($Local) { [IO.File]::ReadAllBytes([string]$a.url) } else {
                $tmp = Join-Path $work 'download.bin'
                Invoke-WebRequest ([string]$a.url) -OutFile $tmp -UseBasicParsing -Headers @{ 'User-Agent' = $UA } -TimeoutSec 120
                $b = [IO.File]::ReadAllBytes($tmp); Remove-Item $tmp -Force; $b
            }
            $info = Test-Pack $bytes $game
            $r = Publish-Pack $info $bytes $poster $cat
            $changed = $true
            React $m $OK_URL
            $what = "$($info.strats) strat$(if ($info.strats -eq 1) { '' } else { 's' }), $($info.agents -join ', '), on $($info.maps -join ', ')"
            $verb = if ($r.updated) { 'Updated' } else { 'Published' }
            Reply $m "$verb **$($info.name)** ($what). It shows up in Stratlab under Packs > Browse within a few minutes. Post the pack again to update it, or write ``remove $($info.name)`` to take it down."
        } elseif ([string]$m.content -match '^\s*(?:remove|delete|unpublish)\s+(.+?)\s*$') {
            $nm = Remove-Pack $cat $Matches[1] $poster
            $changed = $true
            React $m $OK_URL
            Reply $m "Removed **$nm** from the catalog. Copies people already installed stay in their libraries."
        }
    } catch {
        $why = $_.Exception.Message
        Write-Host "  rejected: $why"
        try { React $m $NO_URL; Reply $m "Could not publish this: $why" } catch { Write-Host "  (could not reply: $($_.Exception.Message))" }
    }
}
if ($changed) { Write-Catalog $cat }
if (-not $Local -and $last) { Write-Json $statePath ([ordered]@{ lastMessageId = $last }) }
Write-Host "done: $($cat.packs.Count) pack(s) in the catalog$(if ($changed) { ' (changed)' })"
