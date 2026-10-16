// Estado de las instalaciones en curso, compartido entre la lista y la ficha de una app.
//
// Las instalaciones de iOS se van de Safari (itms-services), así que la página sigue la descarga
// del .ipa en el servidor: /api/progress/<build> dice cuánto lleva bajado este dispositivo.

/** id de build → { phase: 'waiting'|'downloading'|'installing'|'done'|'failed', fraction } */
export const installs = $state({})

export function follow(build, onDone) {
  if (!build.progressPath || installs[build.id]?.active) return
  const started = Date.now() / 1000
  let completedAt = 0
  installs[build.id] = { active: true, phase: 'waiting', fraction: 0 }

  const timer = setInterval(async () => {
    let progress = null
    try {
      const response = await fetch(`/api/progress/${build.progressPath}`, { cache: 'no-store' })
      progress = response.ok ? await response.json() : null
    } catch {
      progress = null
    }
    const now = Date.now() / 1000
    if (!progress || progress.updatedAt < started - 2) {
      // Aún nada: se canceló la confirmación o el iPhone no ha empezado.
      if (now - started > 60) end(null)
      return
    }
    if (progress.state === 'failed') return end('failed')
    if (progress.state === 'completed') {
      completedAt ||= now
      installs[build.id] = { active: true, phase: 'installing', fraction: 1 }
      if (now - completedAt > 5) end('done')
      return
    }
    const fraction = progress.total ? progress.sent / progress.total : 0
    installs[build.id] = { active: true, phase: 'downloading', fraction }
  }, 500)

  function end(result) {
    clearInterval(timer)
    if (!result) {
      delete installs[build.id]
      return
    }
    installs[build.id] = { active: false, phase: result, fraction: 1 }
    if (result === 'done') onDone?.()
    setTimeout(() => delete installs[build.id], 8000)
  }
}
