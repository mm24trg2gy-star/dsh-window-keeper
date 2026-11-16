/**
 * Host 半部冒烟测试：在临时目录里跑 apply()，验证脚本铺设、路由与配置读写。
 * 不启动真实的窗口守护（config.enabled=false），不会碰你的桌面窗口。
 *
 *   node tests/host.smoke.mjs
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import assert from 'node:assert/strict'

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-window-keeper-test-'))
const dataDir = path.join(tmp, 'data')
const appData = path.join(tmp, 'roaming')
fs.mkdirSync(dataDir, { recursive: true })
fs.mkdirSync(appData, { recursive: true })
// 先写关闭状态，避免冒烟测试真的拉起守护进程
fs.writeFileSync(path.join(dataDir, 'config.json'), JSON.stringify({ enabled: false, autostart: false }))

process.env.DSH_WINDOW_KEEPER_DIR = dataDir
process.env.APPDATA = appData
process.env.LOCALAPPDATA = path.join(tmp, 'local')

const { apply, name, inject } = await import('../lib/index.js')

assert.equal(name, 'dsh-window-keeper')
assert.deepEqual(inject, ['webServer'])

const routes = []
let cleanup = null
const ctx = {
  get(key) {
    if (key !== 'webServer') return undefined
    return {
      register(route) {
        routes.push(route)
        return () => {}
      }
    }
  },
  effect(fn) {
    cleanup = fn()
  },
  logger: { warn() {} }
}

apply(ctx)

assert.ok(fs.existsSync(path.join(dataDir, 'window-keeper.ps1')), '脚本未铺设')
assert.ok(!fs.existsSync(path.join(dataDir, 'start-hidden.vbs')), '不应再生成 vbs')
assert.ok(fs.existsSync(path.join(dataDir, 'config.json')), '配置未生成')
assert.equal(routes.length, 3, '应注册 3 条路由')
// autostart=false 时不应写启动项
assert.ok(!fs.existsSync(path.join(appData, 'Microsoft/Windows/Start Menu/Programs/Startup/dsh-window-keeper.lnk')))

function fakeRes() {
  const res = { code: 0, body: '' }
  res.writeHead = (code) => { res.code = code }
  res.end = (buf) => { res.body = String(buf) }
  return res
}

function fakeReq(method, body) {
  const listeners = {}
  const req = {
    method,
    on(event, fn) { (listeners[event] = listeners[event] || []).push(fn) },
    destroy() {}
  }
  // 异步投递请求体，模拟真实流
  setImmediate(() => {
    if (body !== undefined) (listeners.data || []).forEach((fn) => fn(Buffer.from(body)))
    ;(listeners.end || []).forEach((fn) => fn())
  })
  return req
}

// GET /window-keeper/state
const stateRoute = routes.find((r) => r.path === '/window-keeper/state')
assert.ok(stateRoute)
const res1 = fakeRes()
await stateRoute.handler({ method: 'GET' }, res1)
const state1 = JSON.parse(res1.body)
assert.equal(state1.ok, true)
assert.equal(state1.installed, true)
assert.equal(state1.running, false)
assert.equal(state1.config.enabled, false)
assert.equal(state1.watchdog, false, '未启用时不应常驻看门狗')
assert.equal(state1.config.watchdogSeconds, 60, '默认 60 秒')
assert.equal(state1.config.watchdogOnce, false, '默认常驻模式')

// POST /window-keeper/config：打开 autostart（仍保持 enabled=false，不拉进程）
const cfgRoute = routes.find((r) => r.path === '/window-keeper/config')
assert.ok(cfgRoute)
const res2 = fakeRes()
await cfgRoute.handler(fakeReq('POST', JSON.stringify({ patch: { autostart: true } })), res2)
const state2 = JSON.parse(res2.body)
assert.equal(state2.ok, true)
assert.equal(state2.config.autostart, true)
assert.equal(state2.config.enabled, false, 'enabled 不应被意外打开')
// 插件不再创建登录自启项（守护跟随宿主进程），旧的 .lnk 应被清掉
assert.ok(!fs.existsSync(path.join(appData, 'Microsoft/Windows/Start Menu/Programs/Startup/dsh-window-keeper.lnk')), '不应再创建自启项')

// 间隔下限 30 秒
const res2b = fakeRes()
await cfgRoute.handler(fakeReq('POST', JSON.stringify({ patch: { watchdogSeconds: 1 } })), res2b)
const state2b = JSON.parse(res2b.body)
assert.equal(state2b.config.watchdogSeconds, 30, '小于 30 秒应被夹到 30')

// 0 = 关闭
const res2c = fakeRes()
await cfgRoute.handler(fakeReq('POST', JSON.stringify({ patch: { watchdogSeconds: 0 } })), res2c)
const state2c = JSON.parse(res2c.body)
assert.equal(state2c.config.watchdogSeconds, 0, '0 表示关闭')

// POST /window-keeper/action：未知 action 应 400
const actionRoute = routes.find((r) => r.path === '/window-keeper/action')
assert.ok(actionRoute)
const res3 = fakeRes()
await actionRoute.handler(fakeReq('POST', JSON.stringify({ action: 'nope' })), res3)
assert.equal(res3.code, 400)

// 清理
if (typeof cleanup === 'function') cleanup()
fs.rmSync(tmp, { recursive: true, force: true })

console.log('PASS host smoke test')
