<#
  ROBOT ARENA — Servidor multiplayer para Windows (não precisa instalar nada)
  ---------------------------------------------------------------------------
  Uso:  clique com o botão direito > "Executar com PowerShell"
        ou no terminal:  powershell -ExecutionPolicy Bypass -File servidor.ps1
  Depois abra no navegador:  http://localhost:8080

  Jogar com outros computadores da rede (LAN):
        execute UMA vez como administrador:
          netsh http add urlacl url=http://+:8080/ user=Todos
        e depois:  powershell -ExecutionPolicy Bypass -File servidor.ps1 -Rede
        Os amigos abrem http://SEU-IP:8080  (libere a porta 8080 no Firewall do Windows)

  O servidor:
   - serve os arquivos do jogo (index.html)
   - gerencia salas públicas e privadas (com código)
   - repassa as mensagens da partida entre os jogadores (o anfitrião da sala roda a simulação)
#>
param([int]$Porta = 8080, [switch]$Rede)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$prefix = if ($Rede) { "http://+:$Porta/" } else { "http://localhost:$Porta/" }
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
  Write-Host "Não foi possível abrir a porta $Porta ($prefix)." -ForegroundColor Red
  if ($Rede) { Write-Host 'Para modo rede, rode uma vez como administrador:  netsh http add urlacl url=http://+:' + $Porta + '/ user=Todos' -ForegroundColor Yellow }
  Read-Host 'Pressione Enter para sair'; exit 1
}
Write-Host "ROBOT ARENA - servidor ativo em $prefix" -ForegroundColor Cyan
Write-Host "Abra http://localhost:$Porta no navegador. Ctrl+C para encerrar." -ForegroundColor Gray

$utf8 = New-Object System.Text.UTF8Encoding($false)
$clients = @{}   # id -> estado da conexão
$rooms = @{}     # código -> sala
$nextId = 1
$mime = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.svg' = 'image/svg+xml'; '.json' = 'application/json'; '.ico' = 'image/x-icon' }

function Send-Text($c, [string]$text) {
  if ($c.ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { return }
  $bytes = $utf8.GetBytes($text)
  $seg = New-Object System.ArraySegment[byte] -ArgumentList (, $bytes)
  try { $c.ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait(3000) | Out-Null } catch { $c.dead = $true }
}
function Send-Json($c, $obj) { Send-Text $c ($obj | ConvertTo-Json -Depth 8 -Compress) }

function Room-State($room) {
  $players = @()
  foreach ($cid in $room.order) { if ($room.info.ContainsKey($cid)) { $players += $room.info[$cid] } }
  return @{ code = $room.code; name = $room.name; mode = $room.mode; max = $room.max; public = $room.public; host = $room.host; status = $room.status; players = $players; opts = $room.opts }
}
function Broadcast-Room($room) {
  $msg = @{ t = 'room'; room = (Room-State $room) } | ConvertTo-Json -Depth 8 -Compress
  foreach ($cid in $room.order) { if ($clients.ContainsKey($cid)) { Send-Text $clients[$cid] $msg } }
}
function New-Code { $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; do { $s = -join (1..5 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] }) } while ($rooms.ContainsKey($s)); return $s }

function Leave-Room($c) {
  if (-not $c.room) { return }
  $code = $c.room; $c.room = $null
  if (-not $rooms.ContainsKey($code)) { return }
  $room = $rooms[$code]
  $room.order = @($room.order | Where-Object { $_ -ne $c.id }); $room.info.Remove($c.id)
  if ($room.host -eq $c.id -or $room.order.Count -eq 0) {
    foreach ($cid in $room.order) { if ($clients.ContainsKey($cid)) { $clients[$cid].room = $null; Send-Json $clients[$cid] @{ t = 'closed'; msg = 'O anfitrião saiu. A sala foi encerrada.' } } }
    $rooms.Remove($code); Write-Host "Sala $code encerrada" -ForegroundColor DarkGray
  } else { Broadcast-Room $room }
}

function Handle-Json($c, [string]$text) {
  try { $m = $text | ConvertFrom-Json } catch { return }
  switch ($m.t) {
    'hello' { $c.name = [string]$m.name; Send-Json $c @{ t = 'welcome'; id = $c.id } }
    'ping' { Send-Json $c @{ t = 'pong'; ts = $m.ts } }
    'list' {
      $list = @(); foreach ($r in $rooms.Values) { if ($r.public -and $r.status -eq 'lobby') { $list += @{ code = $r.code; name = $r.name; mode = $r.mode; players = $r.order.Count; max = $r.max } } }
      Send-Json $c @{ t = 'rooms'; rooms = $list }
    }
    'create' {
      Leave-Room $c
      $code = New-Code
      $room = @{ code = $code; name = [string]$m.name; mode = [string]$m.mode; max = [int]$m.max; public = [bool]$m.public; host = $c.id; status = 'lobby'; order = @($c.id); info = @{}; opts = $m.opts }
      $p = $m.player; $room.info[$c.id] = @{ id = $c.id; name = [string]$p.name; robot = [string]$p.robot; colors = $p.colors; lo = $p.lo; st = $p.st; ready = $true; team = 0 }
      $rooms[$code] = $room; $c.room = $code
      Send-Json $c @{ t = 'joined'; code = $code; you = $c.id }; Broadcast-Room $room
      Write-Host "Sala $code criada por $($p.name) ($($room.mode))" -ForegroundColor Green
    }
    'join' {
      $code = ([string]$m.code).ToUpper()
      if (-not $rooms.ContainsKey($code)) { Send-Json $c @{ t = 'error'; msg = 'Sala não encontrada.' }; return }
      $room = $rooms[$code]
      if ($room.status -ne 'lobby') { Send-Json $c @{ t = 'error'; msg = 'A partida desta sala já começou.' }; return }
      if ($room.order.Count -ge $room.max) { Send-Json $c @{ t = 'error'; msg = 'Sala cheia.' }; return }
      Leave-Room $c
      $p = $m.player; $teamGuess = $room.order.Count % 2
      $room.order += $c.id; $room.info[$c.id] = @{ id = $c.id; name = [string]$p.name; robot = [string]$p.robot; colors = $p.colors; lo = $p.lo; st = $p.st; ready = $false; team = $teamGuess }
      $c.room = $code
      Send-Json $c @{ t = 'joined'; code = $code; you = $c.id }; Broadcast-Room $room
    }
    'leave' { Leave-Room $c }
    'update' {
      if (-not $c.room -or -not $rooms.ContainsKey($c.room)) { return }
      $room = $rooms[$c.room]; $info = $room.info[$c.id]
      foreach ($k in 'robot', 'colors', 'ready', 'team', 'name', 'lo', 'st') { if ($null -ne $m.player.$k) { $info[$k] = $m.player.$k } }
      if ($m.opts -and $room.host -eq $c.id) { $room.opts = $m.opts; if ($m.mode) { $room.mode = [string]$m.mode } }
      Broadcast-Room $room
    }
    'kick' { if ($c.room -and $rooms[$c.room].host -eq $c.id -and $clients.ContainsKey([int]$m.id)) { $k = $clients[[int]$m.id]; Leave-Room $k; Send-Json $k @{ t = 'closed'; msg = 'Você foi removido da sala.' } } }
    'start' {
      if (-not $c.room) { return }; $room = $rooms[$c.room]; if ($room.host -ne $c.id) { return }
      $room.status = 'playing'; $msg = @{ t = 'start'; cfg = $m.cfg; room = (Room-State $room) } | ConvertTo-Json -Depth 10 -Compress
      foreach ($cid in $room.order) { if ($clients.ContainsKey($cid)) { Send-Text $clients[$cid] $msg } }
    }
    'lobby' { if ($c.room -and $rooms[$c.room].host -eq $c.id) { $rooms[$c.room].status = 'lobby'; Broadcast-Room $rooms[$c.room] } }
  }
}

# Mensagens de jogo usam um formato leve para não precisar decodificar JSON a 20-30 vezes por segundo:
#   cliente -> servidor:  R|<destino>|<conteúdo>     destino = all | host | <id>
#   servidor -> cliente:  F|<origem>|<conteúdo>
function Handle-Relay($c, [string]$text) {
  if (-not $c.room -or -not $rooms.ContainsKey($c.room)) { return }
  $room = $rooms[$c.room]
  $i = $text.IndexOf('|', 2); if ($i -lt 0) { return }
  $to = $text.Substring(2, $i - 2); $out = 'F|' + $c.id + '|' + $text.Substring($i + 1)
  if ($to -eq 'all') { foreach ($cid in $room.order) { if ($cid -ne $c.id -and $clients.ContainsKey($cid)) { Send-Text $clients[$cid] $out } } }
  elseif ($to -eq 'host') { if ($clients.ContainsKey($room.host)) { Send-Text $clients[$room.host] $out } }
  else { $tid = [int]$to; if ($clients.ContainsKey($tid) -and ($room.order -contains $tid)) { Send-Text $clients[$tid] $out } }
}

function Start-Receive($c) {
  $c.recv = $c.ws.ReceiveAsync($c.seg, [System.Threading.CancellationToken]::None)
}

function Serve-Http($ctx) {
  $req = $ctx.Request; $res = $ctx.Response
  try {
    $path = [Uri]::UnescapeDataString($req.Url.AbsolutePath.TrimStart('/'))
    if ($path -eq '') { $path = 'index.html' }
    if ($path -match '\.\.' -or $path -match '^[\\/]' -or $path -match ':') { $res.StatusCode = 403; $res.Close(); return }
    $file = Join-Path $root $path
    if (Test-Path $file -PathType Leaf) {
      $bytes = [IO.File]::ReadAllBytes($file); $ext = [IO.Path]::GetExtension($file).ToLower()
      $res.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
      $res.Headers.Add('Cache-Control', 'no-store')
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else { $res.StatusCode = 404 }
  } catch { $res.StatusCode = 500 }
  try { $res.Close() } catch { }
}

$ctxTask = $listener.GetContextAsync()
while ($listener.IsListening) {
  $busy = $false
  if ($ctxTask.IsCompleted) {
    $ctx = $null; try { $ctx = $ctxTask.Result } catch { }
    $ctxTask = $listener.GetContextAsync(); $busy = $true
    if ($ctx) {
      if ($ctx.Request.IsWebSocketRequest) {
        try {
          $wsc = $ctx.AcceptWebSocketAsync([NullString]::Value).GetAwaiter().GetResult()
          $buf = New-Object byte[] 65536
          $c = @{ id = $nextId; ws = $wsc.WebSocket; buf = $buf; seg = (New-Object System.ArraySegment[byte] -ArgumentList (, $buf)); ms = (New-Object System.IO.MemoryStream); room = $null; name = '?'; dead = $false }
          $clients[$nextId] = $c; $nextId++
          Start-Receive $c
        } catch { }
      } else { Serve-Http $ctx }
    }
  }
  foreach ($c in @($clients.Values)) {
    if ($c.dead -or $c.ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
      if ($c.recv -and -not $c.recv.IsCompleted -and -not $c.dead -and $c.ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) { continue }
      Leave-Room $c; $clients.Remove($c.id); try { $c.ws.Dispose() } catch { }; continue
    }
    if ($c.recv.IsCompleted) {
      $busy = $true
      $r = $null; try { $r = $c.recv.Result } catch { $c.dead = $true; continue }
      if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { $c.dead = $true; continue }
      $c.ms.Write($c.buf, 0, $r.Count)
      if ($r.EndOfMessage) {
        $text = $utf8.GetString($c.ms.ToArray()); $c.ms.SetLength(0)
        try { if ($text.StartsWith('R|')) { Handle-Relay $c $text } else { Handle-Json $c $text } } catch { Write-Host "Erro: $_" -ForegroundColor Red }
      }
      if (-not $c.dead) { try { Start-Receive $c } catch { $c.dead = $true } }
    }
  }
  if (-not $busy) { Start-Sleep -Milliseconds 1 }
}
