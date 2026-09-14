/**
 * Regenerate assets/dsh-web.ico + assets/dsh-web.png from the DeepSeek Harness
 * favicon that ships inside your dsh installation.
 *
 * Dev-only tool: it needs `sharp`, which is not a dependency of this package.
 *
 *   npm i -D sharp
 *   node tools/make-icon.mjs
 *   node tools/make-icon.mjs --favicon "C:\path\to\favicon.svg"
 *
 * The icon is only a convenience - the Windows launcher works without running
 * this, because the prebuilt assets are committed.
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repo = dirname(here)
const assets = join(repo, 'assets')

/** Well-known places a dsh install keeps the built web frontend. */
function faviconCandidates() {
	const list = []
	const home = process.env.USERPROFILE ?? process.env.HOME ?? ''
	if (home) list.push(join(home, '.dsh', 'profiles', 'node_modules', '@deepseek-ai', 'dsh-web-frontend', 'dist', 'favicon.svg'))
	const appData = process.env.APPDATA ?? ''
	if (appData) list.push(join(appData, 'npm', 'node_modules', '@deepseek-ai', 'dsh-web-frontend', 'dist', 'favicon.svg'))
	if (process.env.ProgramFiles) list.push(join(process.env.ProgramFiles, 'nodejs', 'node_modules', '@deepseek-ai', 'dsh-web-frontend', 'dist', 'favicon.svg'))
	return list
}

const overrideIndex = process.argv.indexOf('--favicon')
const favicon = overrideIndex >= 0
	? process.argv[overrideIndex + 1]
	: faviconCandidates().find((candidate) => existsSync(candidate))

if (favicon === undefined || !existsSync(favicon)) {
	console.error('make-icon: could not find favicon.svg - pass --favicon <path>')
	process.exit(1)
}

const sharp = (await import('sharp')).default
const svg = readFileSync(favicon, 'utf8')

const size = 256
const radius = Math.round(size * 0.225)
const background = Buffer.from(
	`<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">`
	+ '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
	+ '<stop offset="0" stop-color="#2f6bff"/><stop offset="1" stop-color="#8a3ffc"/>'
	+ '</linearGradient></defs>'
	+ `<rect width="${size}" height="${size}" rx="${radius}" ry="${radius}" fill="url(#g)"/>`
	+ '</svg>',
)

// Rasterize the mark, then recolor it white through its alpha channel so the
// shipped fill (which is colour-scheme dependent) cannot leak into the icon.
const markSize = Math.round(size * 0.62)
const markRgba = await sharp(Buffer.from(svg))
	.resize(markSize, markSize, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
	.ensureAlpha()
	.png()
	.toBuffer()
const alpha = await sharp(markRgba).extractChannel('alpha').png().toBuffer()
const logo = await sharp({ create: { width: markSize, height: markSize, channels: 3, background: '#ffffff' } })
	.joinChannel(alpha)
	.png()
	.toBuffer()

const composed = await sharp(background)
	.composite([{ input: logo, gravity: 'center' }])
	.png()
	.toBuffer()

const pngPath = join(assets, 'dsh-web.png')
writeFileSync(pngPath, composed)

// Multi-size ICO: header + one 16-byte directory entry per image (PNG payload).
const sizes = [256, 128, 64, 48, 32, 16]
const images = []
for (const entry of sizes) {
	images.push({ size: entry, data: await sharp(composed).resize(entry, entry).png().toBuffer() })
}
const header = Buffer.alloc(6)
header.writeUInt16LE(0, 0)
header.writeUInt16LE(1, 2)
header.writeUInt16LE(images.length, 4)
let offset = 6 + images.length * 16
const entries = []
for (const image of images) {
	const entry = Buffer.alloc(16)
	entry.writeUInt8(image.size >= 256 ? 0 : image.size, 0)
	entry.writeUInt8(image.size >= 256 ? 0 : image.size, 1)
	entry.writeUInt16LE(1, 4)
	entry.writeUInt16LE(32, 6)
	entry.writeUInt32LE(image.data.length, 8)
	entry.writeUInt32LE(offset, 12)
	offset += image.data.length
	entries.push(entry)
}
const icoPath = join(assets, 'dsh-web.ico')
writeFileSync(icoPath, Buffer.concat([header, ...entries, ...images.map((image) => image.data)]))

console.log(`source : ${favicon}`)
console.log(`wrote  : ${pngPath}`)
console.log(`wrote  : ${icoPath} (${sizes.join('/')})`)
