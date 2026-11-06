import { fileURLToPath } from 'node:url'
// 生成测试用最小 EPUB（两章），无外部依赖（手写 stored ZIP）。
// 用法：node make-test-epub.mjs <out.epub>
import { writeFileSync } from 'node:fs'

function crc32(buf) {
  let table = crc32.table
  if (!table) {
    table = crc32.table = new Int32Array(256)
    for (let n = 0; n < 256; n++) {
      let c = n
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
      table[n] = c
    }
  }
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function zip(entries) {
  const chunks = []
  const central = []
  let offset = 0
  for (const [name, data] of entries) {
    const buf = Buffer.from(data, 'utf8')
    const crc = crc32(buf)
    const lh = Buffer.alloc(30)
    lh.writeUInt32LE(0x04034b50, 0)
    lh.writeUInt16LE(20, 4)
    lh.writeUInt16LE(0x0800, 6) // UTF-8
    lh.writeUInt16LE(0, 8) // stored
    lh.writeUInt16LE(0, 10)
    lh.writeUInt16LE(0, 12)
    lh.writeUInt32LE(crc, 14)
    lh.writeUInt32LE(buf.length, 18)
    lh.writeUInt32LE(buf.length, 22)
    lh.writeUInt16LE(name.length, 26)
    chunks.push(lh, Buffer.from(name, 'utf8'), buf)
    const ch = Buffer.alloc(46)
    ch.writeUInt32LE(0x02014b50, 0)
    ch.writeUInt16LE(20, 4)
    ch.writeUInt16LE(20, 6)
    ch.writeUInt16LE(0x0800, 8)
    ch.writeUInt16LE(0, 10)
    ch.writeUInt16LE(0, 12)
    ch.writeUInt16LE(0, 14)
    ch.writeUInt32LE(crc, 16)
    ch.writeUInt32LE(buf.length, 20)
    ch.writeUInt32LE(buf.length, 24)
    ch.writeUInt16LE(name.length, 28)
    ch.writeUInt32LE(offset, 42)
    central.push(ch, Buffer.from(name, 'utf8'))
    offset += 30 + name.length + buf.length
  }
  const cd = Buffer.concat(central)
  const eocd = Buffer.alloc(22)
  eocd.writeUInt32LE(0x06054b50, 0)
  eocd.writeUInt16LE(entries.length, 8)
  eocd.writeUInt16LE(entries.length, 10)
  eocd.writeUInt32LE(cd.length, 12)
  eocd.writeUInt32LE(offset, 16)
  return Buffer.concat([...chunks, cd, eocd])
}

const container = `<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>`

const opf = `<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">test-book</dc:identifier>
    <dc:title>测试书</dc:title>
    <dc:language>zh-CN</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>`

const nav = `<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body>
  <nav epub:type="toc"><ol>
    <li><a href="ch1.xhtml">第一章</a></li>
    <li><a href="ch2.xhtml">第二章</a></li>
  </ol></nav>
</body></html>`

const chapter = (no, paras) => `<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>第${no}章</title></head>
<body>
  <h1>第${no}章标题</h1>
  ${paras.map(t => `<p>${t}</p>`).join('\n')}
</body></html>`

const ch1 = chapter('一', [
  '这是第一章的第一段文字，用于测试朗读文本提取。春眠不觉晓，处处闻啼鸟。',
  '第一章第二段：夜来风雨声，花落知多少。朗读时应当从这里继续往后读。',
])
const ch2 = chapter('二', [
  '这是第二章的第一段文字，跳转目标章节。床前明月光，疑是地上霜。',
  '第二章第二段：举头望明月，低头思故乡。高亮批注应该出现在这一段上。',
])

const out = process.argv[2] || 'test-book.epub'
const buf = zip([
  ['mimetype', 'application/epub+zip'],
  ['META-INF/container.xml', container],
  ['OEBPS/content.opf', opf],
  ['OEBPS/nav.xhtml', nav],
  ['OEBPS/ch1.xhtml', ch1],
  ['OEBPS/ch2.xhtml', ch2],
])
writeFileSync(out, buf)
console.log(`wrote ${out} (${buf.length} bytes)`)
