/**
 * dsh-window-keeper — Host 半部（薄外壳）
 *
 * 它自己不搬窗口。窗口逻辑全在 assets/window-keeper.ps1 里，
 * 这个外壳只做三件事：把脚本装到 %LOCALAPPDATA%\dsh-window-keeper、
 * 管开机自启、给设置页提供开关/状态/手动操作。
 *
 * 所以客户端升级、插件系统换代时，窗口记忆本身不受影响。
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const name = 'dsh-window-keeper'
const inject = ['webServer']

const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const VERSION = (() => {
  try { return JSON.parse(fs.readFileSync(path.join(PACKAGE_ROOT, 'package.json'), 'utf8')).version || '0.0.0' }
  catch { return '0.0.0' }
})()

const LOCAL = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local')
const ROAMING = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming')
const SYSTEM32 = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32')
const POWERSHELL = path.join(SYSTEM32, 'WindowsPowerShell', 'v1.0', 'powershell.exe')
const EXPLORER = path.join(process.env.SystemRoot || 'C:\\Windows', 'explorer.exe')
const DATA_DIR = process.env.DSH_WINDOW_KEEPER_DIR || path.join(LOCAL, 'dsh-window-keeper')
const SCRIPT = path.join(DATA_DIR, 'window-keeper.ps1')
const CONFIG_FILE = path.join(DATA_DIR, 'config.json')
const STATE_FILE = path.join(DATA_DIR, 'window-state.json')
const LOG_FILE = path.join(DATA_DIR, 'keeper.log')
const PID_FILE = path.join(DATA_DIR, 'keeper.pid')
const STARTUP_LNK = path.join(ROAMING, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', 'dsh-window-keeper.lnk')

const DEFAULTS = { enabled: true, autostart: true }
const ROUTE = '/window-keeper'

function log(msg) {
  try { fs.appendFileSync(LOG_FILE, new Date().toISOString() + ' shell: ' + msg + '\n') } catch {}
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return null }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', 'utf8')
}

function readConfig() {
  return Object.assign({}, DEFAULTS, readJson(CONFIG_FILE) || {})
}

function writeConfig(patch) {
  const next = Object.assign({}, readConfig(), patch || {})
  writeJson(CONFIG_FILE, next)
  return next
}

function readPid() {
  try {
    const n = parseInt(fs.readFileSync(PID_FILE, 'utf8').trim(), 10)
    return Number.isFinite(n) && n > 0 ? n : 0
  } catch { return 0 }
}

function alive(pid) {
  if (!pid) return false
  try { process.kill(pid, 0); return true } catch { return false }
}

/**
 * 开机自启用 .lnk，而不是 .vbs：
 * 用户名/路径里可能有中文，而 WScript 按 ANSI 读 .vbs，UTF-8 写进去会变乱码、路径解析失败。
 * 快捷方式由 PowerShell 的 WScript.Shell COM 创建，内部按 Unicode 处理，不受代码页影响。
 */
function syncAutostart(on) {
  try {
    // 旧版用的是 .vbs（中文路径会乱码），升级时顺手清掉
    fs.rmSync(path.join(path.dirname(STARTUP_LNK), 'dsh-window-keeper.vbs'), { force: true })
    fs.rmSync(path.join(DATA_DIR, 'start-hidden.vbs'), { force: true })
    if (!on) { fs.rmSync(STARTUP_LNK, { force: true }); return }
    fs.mkdirSync(path.dirname(STARTUP_LNK), { recursive: true })
    const q = (s) => '"' + String(s).replace(/"/g, '`"') + '"'
    const ps = [
      '$ws = New-Object -ComObject WScript.Shell',
      '$sc = $ws.CreateShortcut(' + q(STARTUP_LNK) + ')',
      '$sc.TargetPath = ' + q(POWERSHELL),
      "$sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + q(SCRIPT) + "'",
      '$sc.WindowStyle = 7',
      '$sc.Save()'
    ].join('; ')
    const r = spawnSync(POWERSHELL, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ps], { windowsHide: true, encoding: 'utf8', timeout: 20000 })
    if (r.status !== 0) log('autostart failed: ' + String(r.stderr || '').slice(0, 400))
  } catch (err) {
    log('autostart failed: ' + err.message)
  }
}

/** 把 assets 里的脚本铺到数据目录；返回是否发生了更新 */
function ensureAssets() {
  fs.mkdirSync(DATA_DIR, { recursive: true })
  const src = path.join(PACKAGE_ROOT, 'assets', 'window-keeper.ps1')
  const wanted = fs.readFileSync(src)
  let changed = true
  try { changed = !fs.readFileSync(SCRIPT).equals(wanted) } catch { changed = true }
  if (changed) fs.writeFileSync(SCRIPT, wanted)
  if (!fs.existsSync(CONFIG_FILE)) writeJson(CONFIG_FILE, DEFAULTS)
  syncAutostart(!!readConfig().autostart)
  return changed
}

function startKeeper() {
  try {
    ensureAssets()
    if (alive(readPid())) return { started: false, pid: readPid() }
    spawn(POWERSHELL, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', SCRIPT], {
      detached: true, stdio: 'ignore', windowsHide: true
    }).unref()
    log('start requested')
    return { started: true, pid: 0 }
  } catch (err) {
    log('start failed: ' + err.message)
    return { started: false, pid: 0, error: err.message }
  }
}

function stopKeeper() {
  const pid = readPid()
  if (alive(pid)) {
    try { process.kill(pid); log('stop pid ' + pid) } catch (err) { log('stop failed: ' + err.message) }
  }
  try { fs.rmSync(PID_FILE, { force: true }) } catch {}
}

function applyOnce() {
  try {
    const r = spawnSync(POWERSHELL, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-Apply'], {
      windowsHide: true, encoding: 'utf8', timeout: 20000
    })
    return { ok: r.status === 0, code: r.status, stdout: String(r.stdout || '').slice(-2000), stderr: String(r.stderr || '').slice(-2000) }
  } catch (err) {
    return { ok: false, error: err.message }
  }
}

function logTail(lines) {
  try {
    const text = fs.readFileSync(LOG_FILE, 'utf8')
    return text.trim().split(/\r?\n/).slice(-(lines || 20))
  } catch { return [] }
}

function snapshot() {
  const cfg = readConfig()
  const pid = readPid()
  return {
    ok: true,
    version: VERSION,
    dataDir: DATA_DIR,
    installed: fs.existsSync(SCRIPT),
    running: alive(pid),
    pid: pid || 0,
    config: cfg,
    autostart: fs.existsSync(STARTUP_LNK),
    state: readJson(STATE_FILE),
    log: logTail(20)
  }
}

function sendJson(res, code, payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8')
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': String(body.length)
  })
  res.end(body)
}

function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve) => {
    let size = 0
    const chunks = []
    req.on('data', (c) => {
      size += c.length
      if (size > limit) { req.destroy(); resolve(''); return }
      chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', () => resolve(''))
  })
}

function apply(ctx) {
  const webServer = (typeof ctx.get === 'function' ? ctx.get('webServer') : undefined) || ctx.webServer
  if (!webServer || typeof webServer.register !== 'function') {
    ctx.logger?.warn?.('dsh-window-keeper: webServer unavailable, shell disabled')
    return
  }

  const disposers = []
  const route = (path, handler) => {
    try { disposers.push(webServer.register({ kind: 'exact', path, handler })) } catch (err) { log('route failed: ' + err.message) }
  }

  route(ROUTE + '/state', (req, res) => {
    if ((req.method || 'GET').toUpperCase() !== 'GET') { sendJson(res, 405, { ok: false, error: 'method not allowed' }); return }
    try { sendJson(res, 200, snapshot()) } catch (err) { sendJson(res, 500, { ok: false, error: String(err.message || err) }) }
  })

  route(ROUTE + '/config', async (req, res) => {
    const method = (req.method || 'GET').toUpperCase()
    if (method === 'GET') { sendJson(res, 200, snapshot()); return }
    if (method !== 'POST') { sendJson(res, 405, { ok: false, error: 'method not allowed' }); return }
    const text = await readBody(req)
    let payload = {}
    try { payload = text ? JSON.parse(text) : {} } catch { sendJson(res, 400, { ok: false, error: 'invalid json' }); return }
    try {
      const patch = payload && typeof payload.patch === 'object' ? payload.patch : payload
      const cfg = writeConfig({
        enabled: patch.enabled === undefined ? readConfig().enabled : !!patch.enabled,
        autostart: patch.autostart === undefined ? readConfig().autostart : !!patch.autostart
      })
      syncAutostart(cfg.autostart)
      if (cfg.enabled) startKeeper()
      else stopKeeper()
      log('config ' + JSON.stringify(cfg))
      sendJson(res, 200, snapshot())
    } catch (err) {
      sendJson(res, 500, { ok: false, error: String(err.message || err) })
    }
  })

  route(ROUTE + '/action', async (req, res) => {
    if ((req.method || 'GET').toUpperCase() !== 'POST') { sendJson(res, 405, { ok: false, error: 'method not allowed' }); return }
    const text = await readBody(req)
    let payload = {}
    try { payload = text ? JSON.parse(text) : {} } catch { sendJson(res, 400, { ok: false, error: 'invalid json' }); return }
    const action = payload && payload.action
    try {
      let result = {}
      if (action === 'apply') result = applyOnce()
      else if (action === 'restart') { stopKeeper(); startKeeper(); result = { ok: true } }
      else if (action === 'reinstall') { ensureAssets(); result = { ok: true, reinstalled: true } }
      else if (action === 'openDir') {
        try { spawn(EXPLORER, [DATA_DIR], { detached: true, stdio: 'ignore', windowsHide: true }).unref(); result = { ok: true } }
        catch (err) { result = { ok: false, error: err.message } }
      } else {
        sendJson(res, 400, { ok: false, error: 'unknown action' }); return
      }
      sendJson(res, 200, Object.assign({ ok: true }, result, snapshot()))
    } catch (err) {
      sendJson(res, 500, { ok: false, error: String(err.message || err) })
    }
  })

  try {
    ensureAssets()
    if (readConfig().enabled) startKeeper()
  } catch (err) {
    log('boot failed: ' + err.message)
  }

  if (typeof ctx.effect === 'function') {
    ctx.effect(() => () => {
      for (const d of disposers.splice(0)) { try { if (typeof d === 'function') d() } catch {} }
      try { stopKeeper() } catch {}
    })
  }
}

export { name, inject, apply }
