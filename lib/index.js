/**
 * dsh-web-desktop - open the DeepSeek Harness Web GUI in a Chrome app window.
 *
 * Mounted by this package's own bundle patch (`cordis.patch.yml`), which turns
 * the Web profile's browser handoff off and inserts this row. On readiness -
 * the same moment the built-in handoff would have run - this plugin resolves
 * the authenticated GUI URL and launches Google Chrome with `--app=<url>`.
 *
 * That matters on Windows: an `--app=` window has no address bar, gets its own
 * taskbar button (Chromium builds a distinct AppUserModelID for app windows),
 * and carries the harness icon from the site favicon instead of the browser's.
 *
 * `dsh web --no-open` keeps this plugin quiet: the flag means somebody else
 * already takes care of opening the GUI (the bundled Windows launcher does).
 *
 * @module dsh-web-desktop
 */

import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { delimiter, join } from 'node:path'

/** Stable Cordis plugin name. */
export const name = 'web-desktop'

/** Services required before this plugin can run. */
export const inject = ['webStartup']

/**
 * Chrome install locations checked when `chrome` is not on PATH.
 * @param platform - `process.platform`.
 * @param env - `process.env`.
 * @returns absolute candidate paths, most likely first.
 */
function chromeCandidates(platform, env) {
	const list = []
	if (platform === 'win32') {
		for (const base of [env.LOCALAPPDATA, env.ProgramFiles, env['ProgramFiles(x86)']]) {
			if (base) list.push(join(base, 'Google', 'Chrome', 'Application', 'chrome.exe'))
		}
	} else if (platform === 'darwin') {
		list.push('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
		list.push(join(env.HOME ?? '', 'Applications/Google Chrome.app/Contents/MacOS/Google Chrome'))
	}
	return list
}

/**
 * Resolve an executable on PATH, mirroring what a shell would do.
 * @param command - bare executable name.
 * @param env - environment carrying PATH/PATHEXT.
 * @returns the first existing absolute path, or undefined.
 */
function which(command, env) {
	const path = env.PATH ?? env.Path ?? ''
	if (path === '') return undefined
	const extensions = process.platform === 'win32'
		? (env.PATHEXT ?? '.COM;.EXE;.BAT;.CMD').split(';').filter((entry) => entry !== '')
		: ['']
	for (const dir of path.split(delimiter)) {
		if (dir === '') continue
		for (const extension of extensions) {
			const candidate = join(dir, command + extension)
			if (existsSync(candidate)) return candidate
		}
	}
	return undefined
}

/**
 * Find Google Chrome.
 * @param override - explicit path from the plugin config, when given.
 * @returns an absolute executable path, or undefined when Chrome is missing.
 */
export function findChrome(override) {
	if (typeof override === 'string' && override !== '') return existsSync(override) ? override : undefined
	const names = process.platform === 'win32'
		? ['chrome.exe']
		: process.platform === 'darwin'
			? []
			: ['google-chrome', 'google-chrome-stable']
	for (const candidate of chromeCandidates(process.platform, process.env)) {
		if (existsSync(candidate)) return candidate
	}
	for (const candidate of names) {
		const found = which(candidate, process.env)
		if (found !== undefined) return found
	}
	return undefined
}

/**
 * Read this plugin's config, tolerating a bare `{}` (the row ships no schema).
 * @param config - raw row config from the loader.
 * @returns normalized options.
 */
function normalizeConfig(config) {
	const raw = config !== null && typeof config === 'object' ? config : {}
	return {
		browserPath: typeof raw.browserPath === 'string' && raw.browserPath !== '' ? raw.browserPath : undefined,
		extraArgs: Array.isArray(raw.extraArgs) ? raw.extraArgs.filter((entry) => typeof entry === 'string') : [],
	}
}

/**
 * Launch Chrome in app mode, detached, so the GUI outlives nothing and dsh
 * never waits on it.
 * @param executable - Chrome executable.
 * @param url - authenticated GUI URL.
 * @param extraArgs - extra Chrome flags from the config.
 */
function launchAppWindow(executable, url, extraArgs) {
	const child = spawn(executable, [`--app=${url}`, ...extraArgs], { detached: true, stdio: 'ignore' })
	child.unref()
}

/**
 * Plugin entry point.
 * @param ctx - Cordis context carrying `webStartup`.
 * @param config - row config (`browserPath`, `extraArgs`).
 */
export function apply(ctx, config) {
	const startup = ctx.get('webStartup')
	// `--no-open` is an explicit "do not open anything" from the caller.
	if (startup === undefined || startup.openBrowser === false) return
	const options = normalizeConfig(config)

	ctx.inject(['webServer', 'connection'], (webCtx) => {
		const announce = () => {
			try {
				const server = webCtx.get('webServer')
				const connection = webCtx.get('connection')
				if (server === undefined || connection === undefined) return
				const host = server.host === undefined || server.host === '' || server.host === '0.0.0.0' ? '127.0.0.1' : server.host
				const url = connection.authenticatedUrl(`http://${host}:${server.port}/`)
				const executable = findChrome(options.browserPath)
				if (executable === undefined) {
					console.error(`[web-desktop] Google Chrome not found - open this URL yourself: ${url}`)
					return
				}
				launchAppWindow(executable, url, options.extraArgs)
			} catch (error) {
				const reason = error instanceof Error ? error.message : String(error)
				console.error(`[web-desktop] could not open the Chrome app window: ${reason}`)
			}
		}
		// Wait for the same readiness gate the built-in handoff uses: the loader
		// tree settled and the connection service is authenticating requests.
		const loader = webCtx.get('loader')
		const settled = typeof loader?.await === 'function' ? loader.await() : undefined
		if (settled === undefined) announce()
		else settled.then(() => announce(), () => {})
	})
}
