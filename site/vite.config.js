import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { defineConfig } from 'vite'
import { DOWNLOAD_URL, NAME, REPO_URL, TAGLINE } from './src/config.js'

// The name may change before release, so index.html takes it from config.js at build time.
const configPlugin = {
  name: 'config-html',
  transformIndexHtml: (html) => html
    .replaceAll('{{NAME}}', NAME)
    .replaceAll('{{TAGLINE}}', TAGLINE)
    .replaceAll('{{REPO_URL}}', REPO_URL)
    .replaceAll('{{DOWNLOAD_URL}}', DOWNLOAD_URL),
}

// Dev-only: lets render.html write its PNGs into the app's resources, or with to=site into public/.
const savePlugin = {
  name: 'save-render',
  configureServer(server) {
    server.middlewares.use('/__save', (req, res) => {
      const params = new URL(req.url, 'http://x').searchParams
      const name = params.get('name')
      const ext = params.get('ext') ?? 'png'
      const site = params.get('to') === 'site'
      if (!/^[a-z0-9-]+$/.test(name ?? '') || !/^(png|mesh)$/.test(ext)) { res.statusCode = 400; return res.end() }
      const chunks = []
      req.on('data', (c) => chunks.push(c))
      req.on('end', () => {
        const dir = resolve(import.meta.dirname, site ? 'public' : '../Resources/art')
        mkdirSync(dir, { recursive: true })
        writeFileSync(resolve(dir, `${name}.${ext}`), Buffer.concat(chunks))
        res.end('ok')
      })
    })
  },
}

export default defineConfig({
  plugins: [configPlugin, savePlugin],
  server: { port: 5199, strictPort: true },
})
