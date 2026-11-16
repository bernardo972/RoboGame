/*
  ROBOT ARENA — servidor multiplayer em Node.js (sem dependências externas)
  Uso:   node server.js            (porta 8080)
         PORT=3000 node server.js
  Abra:  http://localhost:8080  ou  http://IP-DESTA-MÁQUINA:8080 nos outros computadores.

  O servidor serve o index.html, gerencia salas (públicas e privadas com código) e repassa as
  mensagens da partida. O anfitrião de cada sala executa a simulação (autoritativo) e envia o
  estado; os demais enviam seus comandos. Mesmo protocolo do servidor.ps1.
*/
'use strict';
const http = require('http'), fs = require('fs'), path = require('path'), crypto = require('crypto');
const PORT = +process.env.PORT || 8080, ROOT = __dirname;
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.json': 'application/json', '.ico': 'image/x-icon', '.txt': 'text/plain; charset=utf-8' };

const server = http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  if (p.includes('..')) { res.writeHead(403); return res.end(); }
  const file = path.join(ROOT, p);
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end('404'); }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(data);
  });
});

// ---------- WebSocket mínimo (RFC 6455) ----------
const clients = new Map(); const rooms = new Map(); let nextId = 1;
server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key']; if (!key) return socket.destroy();
  const accept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
  socket.setNoDelay(true);
  const c = { id: nextId++, socket, buf: Buffer.alloc(0), frags: [], room: null, name: '?' };
  clients.set(c.id, c);
  socket.on('data', d => { c.buf = Buffer.concat([c.buf, d]); parseFrames(c); });
  const bye = () => { if (!clients.has(c.id)) return; leaveRoom(c); clients.delete(c.id); };
  socket.on('close', bye); socket.on('error', bye);
});
function parseFrames(c) {
  for (;;) {
    const b = c.buf; if (b.length < 2) return;
    const fin = b[0] & 0x80, op = b[0] & 0x0f, masked = b[1] & 0x80; let len = b[1] & 0x7f, off = 2;
    if (len === 126) { if (b.length < 4) return; len = b.readUInt16BE(2); off = 4; }
    else if (len === 127) { if (b.length < 10) return; len = Number(b.readBigUInt64BE(2)); off = 10; }
    const mo = off; if (masked) off += 4; if (b.length < off + len) return;
    let payload = b.slice(off, off + len);
    if (masked) { const m = b.slice(mo, mo + 4); payload = Buffer.from(payload); for (let i = 0; i < payload.length; i++) payload[i] ^= m[i & 3]; }
    c.buf = b.slice(off + len);
    if (op === 8) { c.socket.end(); return; }
    if (op === 9) { sendFrame(c, payload, 0xA); continue; }
    if (op === 0 || op === 1) { c.frags.push(payload); if (fin) { const text = Buffer.concat(c.frags).toString('utf8'); c.frags = []; onText(c, text); } }
  }
}
function sendFrame(c, data, op = 1) {
  const p = Buffer.isBuffer(data) ? data : Buffer.from(data, 'utf8'); let h;
  if (p.length < 126) { h = Buffer.from([0x80 | op, p.length]); }
  else if (p.length < 65536) { h = Buffer.alloc(4); h[0] = 0x80 | op; h[1] = 126; h.writeUInt16BE(p.length, 2); }
  else { h = Buffer.alloc(10); h[0] = 0x80 | op; h[1] = 127; h.writeBigUInt64BE(BigInt(p.length), 2); }
  try { c.socket.write(Buffer.concat([h, p])); } catch (e) { }
}
const sendJson = (c, o) => sendFrame(c, JSON.stringify(o));

// ---------- salas ----------
function roomState(r) { return { code: r.code, name: r.name, mode: r.mode, max: r.max, public: r.public, host: r.host, status: r.status, opts: r.opts, players: r.order.map(id => r.info.get(id)).filter(Boolean) }; }
function broadcastRoom(r) { const m = JSON.stringify({ t: 'room', room: roomState(r) }); for (const id of r.order) { const c = clients.get(id); if (c) sendFrame(c, m); } }
function newCode() { const ch = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; let s; do { s = ''; for (let i = 0; i < 5; i++) s += ch[Math.floor(Math.random() * ch.length)]; } while (rooms.has(s)); return s; }
function leaveRoom(c) {
  if (!c.room) return; const r = rooms.get(c.room); c.room = null; if (!r) return;
  r.order = r.order.filter(id => id !== c.id); r.info.delete(c.id);
  if (r.host === c.id || r.order.length === 0) {
    for (const id of r.order) { const o = clients.get(id); if (o) { o.room = null; sendJson(o, { t: 'closed', msg: 'O anfitrião saiu. A sala foi encerrada.' }); } }
    rooms.delete(r.code); console.log('Sala ' + r.code + ' encerrada');
  } else broadcastRoom(r);
}
function onText(c, text) {
  if (text.startsWith('R|')) { // repasse leve de mensagens da partida
    const r = rooms.get(c.room); if (!r) return; const i = text.indexOf('|', 2); if (i < 0) return;
    const to = text.slice(2, i), out = 'F|' + c.id + '|' + text.slice(i + 1);
    if (to === 'all') { for (const id of r.order) if (id !== c.id) { const o = clients.get(id); if (o) sendFrame(o, out); } }
    else if (to === 'host') { const o = clients.get(r.host); if (o) sendFrame(o, out); }
    else { const o = clients.get(+to); if (o && r.order.includes(o.id)) sendFrame(o, out); }
    return;
  }
  let m; try { m = JSON.parse(text); } catch (e) { return; }
  switch (m.t) {
    case 'hello': c.name = String(m.name || '?'); sendJson(c, { t: 'welcome', id: c.id }); break;
    case 'ping': sendJson(c, { t: 'pong', ts: m.ts }); break;
    case 'list': sendJson(c, { t: 'rooms', rooms: [...rooms.values()].filter(r => r.public && r.status === 'lobby').map(r => ({ code: r.code, name: r.name, mode: r.mode, players: r.order.length, max: r.max })) }); break;
    case 'create': {
      leaveRoom(c); const code = newCode(), p = m.player || {};
      const r = { code, name: String(m.name || 'SALA'), mode: String(m.mode || 'ffa'), max: +m.max || 8, public: !!m.public, host: c.id, status: 'lobby', order: [c.id], info: new Map(), opts: m.opts || {} };
      r.info.set(c.id, { id: c.id, name: p.name, robot: p.robot, colors: p.colors, lo: p.lo, st: p.st, ready: true, team: 0 });
      rooms.set(code, r); c.room = code; sendJson(c, { t: 'joined', code, you: c.id }); broadcastRoom(r); console.log('Sala ' + code + ' criada por ' + p.name);
      break;
    }
    case 'join': {
      const r = rooms.get(String(m.code || '').toUpperCase());
      if (!r) return sendJson(c, { t: 'error', msg: 'Sala não encontrada.' });
      if (r.status !== 'lobby') return sendJson(c, { t: 'error', msg: 'A partida desta sala já começou.' });
      if (r.order.length >= r.max) return sendJson(c, { t: 'error', msg: 'Sala cheia.' });
      leaveRoom(c); const p = m.player || {};
      r.order.push(c.id); r.info.set(c.id, { id: c.id, name: p.name, robot: p.robot, colors: p.colors, lo: p.lo, st: p.st, ready: false, team: (r.order.length - 1) % 2 });
      c.room = r.code; sendJson(c, { t: 'joined', code: r.code, you: c.id }); broadcastRoom(r);
      break;
    }
    case 'leave': leaveRoom(c); break;
    case 'update': {
      const r = rooms.get(c.room); if (!r) return; const info = r.info.get(c.id);
      for (const k of ['robot', 'colors', 'ready', 'team', 'name', 'lo', 'st']) if (m.player && m.player[k] !== undefined) info[k] = m.player[k];
      if (m.opts && r.host === c.id) { r.opts = m.opts; if (m.mode) r.mode = m.mode; }
      broadcastRoom(r); break;
    }
    case 'kick': { const r = rooms.get(c.room); if (!r || r.host !== c.id) return; const k = clients.get(+m.id); if (k) { leaveRoom(k); sendJson(k, { t: 'closed', msg: 'Você foi removido da sala.' }); } break; }
    case 'start': { const r = rooms.get(c.room); if (!r || r.host !== c.id) return; r.status = 'playing'; const msg = JSON.stringify({ t: 'start', cfg: m.cfg, room: roomState(r) }); for (const id of r.order) { const o = clients.get(id); if (o) sendFrame(o, msg); } break; }
    case 'lobby': { const r = rooms.get(c.room); if (r && r.host === c.id) { r.status = 'lobby'; broadcastRoom(r); } break; }
  }
}
server.listen(PORT, () => {
  const ips = Object.values(require('os').networkInterfaces()).flat().filter(i => i && i.family === 'IPv4' && !i.internal).map(i => i.address);
  console.log('ROBOT ARENA — servidor multiplayer ativo');
  console.log('  Neste computador:   http://localhost:' + PORT);
  for (const ip of ips) console.log('  Na rede local:      http://' + ip + ':' + PORT);
});
