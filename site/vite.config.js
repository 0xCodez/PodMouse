import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { defineConfig } from 'vite'

// Dev-only: lets render.html write its PNGs into the app's resources.
const savePlugin = {
  name: 'save-render',
  configureServer(server) {
    server.middlewares.use('/__save', (req, res) => {
      const params = new URL(req.url, 'http://x').searchParams
      const name = params.get('name')
      const ext = params.get('ext') ?? 'png'
      if (!/^[a-z0-9-]+$/.test(name ?? '') || !/^(png|mesh)$/.test(ext)) { res.statusCode = 400; return res.end() }
      const chunks = []
      req.on('data', (c) => chunks.push(c))
      req.on('end', () => {
        const dir = resolve(import.meta.dirname, '../Resources/art')
        mkdirSync(dir, { recursive: true })
        writeFileSync(resolve(dir, `${name}.${ext}`), Buffer.concat(chunks))
        res.end('ok')
      })
    })
  },
}

export default defineConfig({
  plugins: [savePlugin],
  server: { port: 5199, strictPort: true },
})
