# Sonidos de CodeOS

Aquí van los sonidos de la interfaz de CodeOS, uno por acción: `enter`, `move`, `tab`, `select`, `back`, `launch`, `panel`,
`panelClose`, `home` y `notify` (en `.flac`, `.wav`, `.mp3`, `.m4a` o `.aiff`).

Los `.flac` de esta carpeta **no se suben al repositorio** (son sonidos del sistema de PlayStation 5, de Sony, y el repositorio es
público): `.gitignore` los excluye. Xcode los mete en `Jack.app` si están aquí al compilar; si no están, CodeOS busca en
`~/Library/Application Support/Jack/CodeOS/Sounds` y, si tampoco, usa campanas sintetizadas por código.
