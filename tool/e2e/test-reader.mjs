import { fileURLToPath } from 'node:url'
// 无头 Chromium 验证 foliate 引擎（host.html + 书籍字节服务器同构模拟）。
// 用法：node test-reader.mjs <bookPath>
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { extname, join, normalize } from 'node:path'
import { existsSync } from 'node:fs'

const BOOK = process.argv[2]
if (!BOOK || !existsSync(BOOK)) {
  console.error('usage: node test-reader.mjs <book file>')
  process.exit(1)
}
const bookBytes = await readFile(BOOK)
const ext = extname(BOOK).toLowerCase()
const contentType = ext === '.pdf' ? 'application/pdf' : 'application/epub+zip'

const READER_ROOT = fileURLToPath(new URL('../../assets/reader', import.meta.url))
const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json',
  '.bcmap': 'application/octet-stream', '.pfb': 'application/octet-stream',
  '.ttf': 'font/ttf', '.map': 'application/json',
}

const server = createServer(async (req, res) => {
  console.log('[req]', req.url)
  try {
    if (req.url === '/book/main') {
      res.writeHead(200, { 'Content-Type': contentType, 'Access-Control-Allow-Origin': '*' })
      res.end(bookBytes)
      return
    }
    let p = req.url.split('?')[0].replace(/^\/+/, '')
    if (p === '' || p.endsWith('/')) p += 'host.html'
    const file = join(READER_ROOT, ...p.split('/'))
    if (!file.startsWith(READER_ROOT) || !existsSync(file)) {
      console.log('[404]', p)
      res.writeHead(404); res.end('not found ' + p); return
    }
    res.writeHead(200, { 'Content-Type': MIME[extname(file)] ?? 'application/octet-stream' })
    res.end(await readFile(file))
  } catch (e) {
    res.writeHead(500); res.end(String(e))
  }
})
await new Promise(r => server.listen(8412, '127.0.0.1', r))
console.log('static server on 8412')

const { chromium } = await import('playwright-core')
const executablePath = [
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
].find(p => existsSync(p))
const browser = await chromium.launch({
  executablePath,
  headless: true,
  args: ['--no-sandbox', '--disable-gpu', '--enable-unsafe-swiftshader'],
})
const page = await browser.newPage({ viewport: { width: 800, height: 1100 } })
const events = []
const consoleLogs = []
await page.addInitScript(() => {
  window.__events = []
  window.flutter_inappwebview = {
    callHandler: (name, msg) => {
      window.__events.push({ name, payload: msg?.payload })
    },
  }
})
page.on('console', m => consoleLogs.push(`[${m.type()}] ${m.text()}`))
page.on('pageerror', e => consoleLogs.push(`[pageerror] ${e.message}`))

await page.goto('http://127.0.0.1:8412/host.html', { waitUntil: 'load' })
await page.waitForTimeout(1500)
console.log('--- console so far ---')
consoleLogs.forEach(l => console.log(l))
console.log('__foliate defined:', await page.evaluate(() => typeof window.__foliate))
if (await page.evaluate(() => typeof window.__foliate) === 'undefined') {
  await browser.close(); server.close(); process.exit(2)
}

console.log('--- opening book ---')
const openResult = await page.evaluate(async () => {
  const r = await window.__foliate.open('http://127.0.0.1:8412/book/main')
  return r
})
console.log('open() =>', JSON.stringify(openResult))

// 应用层流程：book-ready 后 applyInitialSettings → restore(null)
await page.evaluate(() => window.__foliate.restore(null))
await page.waitForTimeout(5000)

console.log('--- console after open ---')
consoleLogs.slice(-30).forEach(l => console.log(l))

console.log('--- events (relocate 完整负载) ---')
const ev = await page.evaluate(() => window.__events)
for (const e of ev.slice(-6)) {
  console.log(JSON.stringify(e).slice(0, 1200))
}

console.log('--- engine state ---')
const state = await page.evaluate(() => {
  const view = document.getElementById('view')
  return {
    bookLoaded: !!view.book,
    format: view.book?.format ?? null,
    fixedLayout: !!view.isFixedLayout,
    rendererTag: view.renderer?.tagName?.toLowerCase() ?? null,
    sections: view.book?.sections?.length ?? 0,
    tocLen: view.book?.toc?.length ?? 0,
    lastLocation: view.lastLocation ?? null,
    rendererPage: view.renderer?.page ?? null,
    rendererPages: view.renderer?.pages ?? null,
    rendererIndex: view.renderer?.index ?? null,
    textLen: view.renderer?.getContents?.()?.[0]?.doc?.body?.innerText?.length ?? 0,
  }
})
console.log(JSON.stringify(state, null, 2))

console.log('--- getSectionText (TTS 数据源) ---')
const st = await page.evaluate(async () => {
  const r = await window.__foliate.getSectionText()
  return { index: r.index, label: r.label, textLen: (r.text || '').length, head: (r.text || '').slice(0, 80) }
})
console.log(JSON.stringify(st, null, 2))

console.log('--- annotation delete/add test (epub) ---')
const annoTest = await page.evaluate(async () => {
  const out = {}
  try {
    // 注入一条假高亮再删除，验证桥的传参契约
    const label = 'epubcfi(/6/2!/4/2/1:0)'
    try {
      const r1 = await window.__foliate.deleteAnnotation(label)
      out.deleteStr = r1
    } catch (e) { out.deleteStrErr = String(e) }
    try {
      const r2 = await window.__foliate.deleteAnnotation({ value: label })
      out.deleteObj = r2
    } catch (e) { out.deleteObjErr = String(e) }
  } catch (e) { out.err = String(e) }
  return out
})
console.log(JSON.stringify(annoTest, null, 2))

await browser.close()
server.close()
process.exit(0)
