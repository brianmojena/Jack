const time = new Intl.DateTimeFormat('es-ES', { hour: '2-digit', minute: '2-digit' })
const day = new Intl.DateTimeFormat('es-ES', { day: 'numeric', month: 'short' })
const full = new Intl.DateTimeFormat('es-ES', { day: 'numeric', month: 'short', year: 'numeric' })

/** "Hoy, 15:29", "Ayer, 9:02", "7 oct, 11:45" o "7 oct 2025" si es de otro año. */
export function when(iso) {
  const date = new Date(iso)
  const today = new Date()
  const startOf = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  const days = Math.round((startOf(today) - startOf(date)) / 86_400_000)
  if (days === 0) return `Hoy, ${time.format(date)}`
  if (days === 1) return `Ayer, ${time.format(date)}`
  if (date.getFullYear() !== today.getFullYear()) return full.format(date)
  return `${day.format(date)}, ${time.format(date)}`
}

export function dateTime(iso) {
  const date = new Date(iso)
  return `${full.format(date)}, ${time.format(date)}`
}

export function versionText(build) {
  return `${build.version} (${build.build})`
}
