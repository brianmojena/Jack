# Sonidos de CodeOS

Los sonidos de la interfaz de CodeOS, uno por acción: `enter`, `move`, `tab`, `select`, `back`, `launch`, `panel`, `panelClose`, `home` y
`notify` (en `.flac`, `.wav`, `.mp3`, `.m4a` o `.aiff`). Xcode los mete en `Jack.app/Contents/Resources/Sounds` al compilar, y CodeOS los
busca primero ahí, luego en `~/Library/Application Support/Jack/CodeOS/Sounds` y, si no hay ninguno, usa campanas sintetizadas por código.

**Aviso:** son sonidos del sistema de PlayStation 5, de Sony. Están en este repositorio solo porque es **privado** y para el uso del
equipo. No hagas público el repositorio ni repartas la app con ellos fuera del equipo sin cambiarlos por sonidos propios.
