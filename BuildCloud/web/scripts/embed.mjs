// Copia dist/index.html dentro de Sources/BuildCloudCore/WebApp.swift como literal de texto,
// para que la app y el CLI sirvan la web sin depender de ficheros externos.
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const html = readFileSync(new URL('../dist/index.html', import.meta.url), 'utf8')
const fence = '#####'
if (html.includes(`"""${fence}`)) throw new Error('El HTML contiene el delimitador del literal de Swift')

const swift = `// Generado por web/scripts/embed.mjs a partir de web/ (Svelte). No editar a mano:
// cambia web/src y ejecuta scripts/build-web.sh.

enum WebApp {
    static let html = ${fence}"""
${html}
"""${fence}
}
`
const target = fileURLToPath(new URL('../../Sources/BuildCloudCore/WebApp.swift', import.meta.url))
writeFileSync(target, swift)
console.log(`WebApp.swift: ${(html.length / 1024).toFixed(1)} KB`)
