/**
 * dsh-window-keeper — 浏览器半部（设置页「窗口记忆」）
 *
 * 手写 ModuleLoader bundle，无需构建：
 *   window.__ModuleLoader__.load({ id, factory })
 * id 必须等于 loader entry 名（dsh-window-keeper）。
 * 数据不走 dsh-settings，直接读宿主半部的 HTTP 接口，
 * 这样 dsh-settings 换版本也不会把本插件带崩。
 */
window.__ModuleLoader__.load({
  id: 'dsh-window-keeper',
  factory: function (require) {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    var react = require('react')
    var h = react.createElement

    var ROUTE = '/window-keeper'

    var styles = {
      wrap: { display: 'flex', flexDirection: 'column', gap: '12px', padding: '4px 0', color: 'inherit' },
      card: { border: '1px solid rgba(128,128,128,0.3)', borderRadius: '8px', padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: '10px' },
      row: { display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '12px' },
      label: { display: 'flex', alignItems: 'center', gap: '8px', cursor: 'pointer' },
      hint: { fontSize: '12px', opacity: 0.65, lineHeight: 1.5 },
      dot: function (on) {
        return { display: 'inline-block', width: '8px', height: '8px', borderRadius: '50%', background: on ? '#22c55e' : '#9ca3af' }
      },
      btn: { border: '1px solid rgba(128,128,128,0.4)', background: 'transparent', color: 'inherit', borderRadius: '6px', padding: '5px 10px', cursor: 'pointer', fontSize: '13px' },
      pre: { fontSize: '11px', lineHeight: 1.5, background: 'rgba(128,128,128,0.12)', borderRadius: '6px', padding: '8px', margin: 0, maxHeight: '96px', overflow: 'auto', whiteSpace: 'pre-wrap', wordBreak: 'break-all' },
      mono: { fontFamily: 'ui-monospace, Consolas, monospace', fontSize: '12px' }
    }

    function useKeeper() {
      var state = react.useState(null)
      var data = state[0]
      var setData = state[1]
      var busyState = react.useState(false)
      var busy = busyState[0]
      var setBusy = busyState[1]
      var errState = react.useState('')
      var error = errState[0]
      var setError = errState[1]

      function load() {
        fetch(ROUTE + '/state', { headers: { Accept: 'application/json' } })
          .then(function (r) { return r.json() })
          .then(function (j) { setData(j) })
          .catch(function (e) { setError(String(e && e.message || e)) })
      }

      function post(path, body) {
        setBusy(true)
        setError('')
        fetch(ROUTE + path, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
          body: JSON.stringify(body || {})
        })
          .then(function (r) { return r.json() })
          .then(function (j) {
            if (j && j.ok === false) setError(j.error || '操作失败')
            setData(function (old) { return j && j.version ? j : old })
          })
          .catch(function (e) { setError(String(e && e.message || e)) })
          .then(function () { setBusy(false) })
      }

      react.useEffect(function () { load() }, [])
      return { data: data, busy: busy, error: error, load: load, post: post }
    }

    function Row(props) {
      return h('div', { style: styles.row }, props.children)
    }

    function Toggle(props) {
      return h('label', { style: styles.label },
        h('input', {
          type: 'checkbox',
          checked: !!props.checked,
          disabled: !!props.disabled,
          onChange: function (e) { props.onChange(e.target.checked) }
        }),
        h('span', null, props.text)
      )
    }

    function Panel() {
      var k = useKeeper()
      var d = k.data
      var st = d && d.state

      var size = st
        ? (st.width + '×' + st.height + ' @ ' + st.x + ',' + st.y + (st.maximized ? '（最大化）' : ''))
        : '还没有记录（把窗口拖到想要的大小，稍等一秒）'

      return h('div', { style: styles.wrap },
        h('div', { style: styles.card },
          h(Row, null,
            h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px' } },
              h('span', { style: styles.dot(d && d.running) }),
              h('strong', null, d ? (d.running ? '守护运行中' : '守护未运行') : '正在读取…'),
              d && d.pid ? h('span', { style: Object.assign({}, styles.mono, { opacity: 0.6 }) }, 'pid ' + d.pid) : null
            ),
            h('span', { style: styles.hint }, 'v' + (d ? d.version : '?'))
          ),
          h('div', { style: styles.hint }, '记住的尺寸：',
            h('span', { style: Object.assign({}, styles.mono, { opacity: st ? 1 : 0.6 }) }, size)),
          h('div', { style: styles.hint },
            '数据目录：', h('span', { style: styles.mono }, d ? d.dataDir : '…'))
        ),

        h('div', { style: styles.card },
          h(Row, null,
            h(Toggle, {
              text: '启用窗口记忆',
              checked: !!(d && d.config && d.config.enabled),
              disabled: k.busy,
              onChange: function (on) { k.post('/config', { patch: { enabled: on } }) }
            }),
            h(Toggle, {
              text: '登录时自动启动',
              checked: !!(d && d.config && d.config.autostart),
              disabled: k.busy,
              onChange: function (on) { k.post('/config', { patch: { autostart: on } }) }
            })
          ),
          h('div', { style: { display: 'flex', flexWrap: 'wrap', gap: '8px' } },
            h('button', { style: styles.btn, disabled: k.busy, onClick: function () { k.post('/action', { action: 'apply' }) } }, '立即恢复一次'),
            h('button', { style: styles.btn, disabled: k.busy, onClick: function () { k.post('/action', { action: 'restart' }) } }, '重启守护'),
            h('button', { style: styles.btn, disabled: k.busy, onClick: function () { k.post('/action', { action: 'reinstall' }) } }, '重装脚本'),
            h('button', { style: styles.btn, disabled: k.busy, onClick: function () { k.post('/action', { action: 'openDir' }) } }, '打开目录')
          ),
          h('div', { style: styles.hint },
            '脚本本体独立于客户端版本：即使 DSH 升级、插件系统换代，窗口记忆也不受影响；这里只是“安装 + 自启 + 开关”。')
        ),

        k.error ? h('div', { style: { color: '#ef4444', fontSize: '12px' } }, k.error) : null,

        h('div', { style: styles.card },
          h(Row, null,
            h('strong', { style: { fontSize: '13px' } }, '最近日志'),
            h('button', { style: styles.btn, disabled: k.busy, onClick: k.load }, '刷新')
          ),
          h('pre', { style: styles.pre }, d && d.log && d.log.length ? d.log.join('\n') : '（暂无）')
        )
      )
    }

    var inject = ['slots']

    function apply(ctx) {
      ctx.slots.inject('settings.section', function () {
        return ctx.slots.register(
          { name: 'settings.section', id: 'window-keeper', order: 27, label: '窗口记忆' },
          function () { return h(Panel, {}) }
        )
      })
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  }
})
