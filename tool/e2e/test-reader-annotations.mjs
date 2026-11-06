import { fileURLToPath } from 'node:url'
// 无头 Chromium 验证阅读引擎修复：
//   1. sectionText（TTS 数据源）能取到正文（「无可朗读的文本」修复）；
//   2. setAnnotations 批注队列：章节未加载时登记，goTo 到该章节后自动
//      渲染（「退出后/笔记中心跳回后高亮消失」修复）。
// 用法：node make-test-epub.mjs test-book.epub && node test-reader-annotations.mjs
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { extname, join, normalize } from 'node:path'
import { existsSync } from 'node:fs'

const BOOK = fileURLToPath(new URL('./test-book.epub', import.meta.url))
const bookBytes = await readFile(BOOK)
const READER_ROOT = fileURLToPath(new URL('../../assets/reader', import.meta.url))
const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json',
  '.bcmap': 'application/octet-stream', '.pfb': 'application/octet-stream',
  '.ttf': 'font/ttf', '.map': 'application/json',
}

const server = createServer(async (req, res) => {
  try {
    if (req.url === '/book/main') {
      res.writeHead(200, { 'Content-Type': 'application/epub+zip', 'Access-Control-Allow-Origin': '*' })
      res.end(bookBytes)
      return
    }
    let p = req.url.split('?')[0].replace(/^\/+/, '')
    if (p === '' || p.endsWith('/')) p += 'host.html'
    const file = join(READER_ROOT, ...p.split('/'))
    if (!file.startsWith(READER_ROOT) || !existsSync(file)) {
      res.writeHead(404); res.end('not found ' + p); return
    }
    res.writeHead(200, { 'Content-Type': MIME[extname(file)] ?? 'application/octet-stream' })
    res.end(await readFile(file))
  } catch (e) {
    res.writeHead(500); res.end(String(e))
  }
})
await new Promise(r => server.listen(8415, '127.0.0.1', r))

const { chromium } = await import('playwright-core')
const executablePath = [
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
].find(p => existsSync(p))
const browser = await chromium.launch({
  executablePath, headless: true,
  args: ['--no-sandbox', '--disable-gpu', '--enable-unsafe-swiftshader'],
})
const page = await browser.newPage({ viewport: { width: 800, height: 1100 } })
const errors = []
await page.addInitScript(() => {
  window.flutter_inappwebview = { callHandler: () => {} }
})
page.on('pageerror', e => errors.push('pageerror: ' + e.message))
page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()) })

await page.goto('http://127.0.0.1:8415/host.html', { waitUntil: 'load' })
await page.waitForTimeout(1200)

const results = {}

// 打开书（等同 Flutter 的 open + restore(null)）
results.open = await page.evaluate(async () => {
  const r = await window.__foliate.open('http://127.0.0.1:8415/book/main')
  await window.__foliate.restore(null)
  return r
})
await page.waitForTimeout(2500)

results.bookState = await page.evaluate(() => {
  const view = document.getElementById('view')
  return {
    sections: view.book?.sections?.length ?? 0,
    renderer: view.renderer?.tagName?.toLowerCase() ?? null,
    cfis: view.book?.sections?.map(s => s.cfi) ?? [],
  }
})

// 1) getSectionText：TTS 数据源（事件通道 + 返回值双通道）
results.sectionText = await page.evaluate(async () => {
  const r = await window.__foliate.getSectionText()
  return { index: r.index, len: (r.text || '').length, head: (r.text || '').slice(0, 40) }
})

// 2) 生成第二章（未加载）的真实 CFI，模拟「笔记中心跳回」：
//    先在第二章尚未渲染时 setAnnotations，再 goTo，验证自动注入。
results.annotationFlow = await page.evaluate(async () => {
  const view = document.getElementById('view')
  const out = {}

  // 用引擎自己的 createDocument 生成第二章段落 CFI（与真机选中文字同源）
  const doc2 = await view.book.sections[1].createDocument()
  const p2 = doc2.querySelector('p')
  const range2 = doc2.createRange()
  range2.selectNodeContents(p2)
  const cfi2 = view.getCFI(1, range2)

  const preCount = () => {
    const contents = view.renderer.getContents()
    const obj = contents.find(x => x.index === 1 && x.overlayer)
    return obj ? obj.overlayer.element.childElementCount : -1
  }
  out.beforeGoTo = preCount() // 章节2还没加载 → -1 或无渲染

  // Flutter 端 _restoreNotes 的行为：一次性灌入全部批注
  await window.__foliate.setAnnotations([
    { value: cfi2, text: '第二章第一段', color: '#facc15', style: 'highlight', note: '' },
  ])

  // 笔记中心跳回：goTo 到该 CFI（等同 restore(cfi)）
  await view.goTo(cfi2)
  await new Promise(r => setTimeout(r, 2200))

  const contents = view.renderer.getContents()
  const obj = contents.find(x => x.index === 1 && x.overlayer)
  out.afterGoToChildren = obj ? obj.overlayer.element.childElementCount : -1
  out.section2Text = contents.find(x => x.index === 1)?.doc?.body?.innerText?.slice(0, 40) ?? ''
  return out
})

console.log(JSON.stringify(results, null, 2))
console.log('--- errors ---')
console.log(errors.slice(0, 20).join('\n'))

await browser.close()
server.close()

const ok =
  results.open?.ok === true &&
  (results.sectionText?.len ?? 0) > 20 &&
  results.annotationFlow?.afterGoToChildren >= 2 // defs + 高亮矩形
console.log(ok ? 'PASS' : 'FAIL')
process.exit(ok ? 0 : 1)
