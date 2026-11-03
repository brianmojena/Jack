# Personalización en Jack (modo Normal)

## Guía rápida

Abre **Ajustes → Personalización**. Pulsa **Nuevo** para crear un mod y personaliza el tema, la distribución y los comandos con los controles rápidos. También puedes editar el JSON directamente: Jack valida y guarda los cambios automáticamente 450 ms después de que dejes de escribir. Un JSON inválido muestra el error y conserva la última versión válida.

Puedes activar varios mods a la vez. El orden de la lista determina la prioridad: el último mod habilitado gana cuando varios definen el mismo campo; los campos que omite no borran los anteriores. **Restablecer** desactiva las personalizaciones y vuelve a los valores normales sin borrar los mods ni sus archivos.

Los mods se guardan en la carpeta de datos de Jack, en `Customization/Packs/`. Los cambios que hagas allí se detectan en vivo, incluso si el archivo se reemplaza atómicamente. Desde Ajustes puedes **Importar** un JSON o **Exportar** un mod para compartirlo o guardarlo en otro lugar.

Los comandos `prompt` aparecen como plantillas para los agentes: escribe `!nombre argumentos` en un chat y Jack sustituye `{{args}}` por esos argumentos. Los comandos `terminal` se usan sin argumentos, como `!repo_status`; en la interfaz Terminal también están disponibles en el menú **Mis comandos**. El contenido del comando de terminal se conserva literal y Jack no lo ejecuta al importar ni al cargar un mod.

Los campos `workspacePosition`, `workspaceWidth`, `workspaceHeight` y `explorerVisible` solo afectan a la distribución cuando hay paneles de chat. `sidebarPosition`, `sidebarWidth`, `sidebarVisible` y `statusBarVisible` también se aplican en Terminal. La escena de Oficina conserva su diseño propio.

La personalización solo está disponible en el modo Normal; no añade controles ni tareas a Light. Puedes probar el [ejemplo Neon Workspace](../Examples/Mods/neon-workspace.json), que incluye tema, distribución y un comando de cada tipo.

## Formato del paquete JSON

Cada archivo UTF-8 debe contener `schemaVersion`, `id`, `name` y `commands`. No se generan valores por defecto para esos campos al importar; `commands` puede ser un arreglo vacío. `schemaVersion` debe ser `1`. `author`, `theme` y `layout` son opcionales. Los campos de `theme` y `layout` también son opcionales: si se omiten, se conservan los valores normales o el valor definido por un mod anterior.

- `id`: de 1 a 64 bytes ASCII, solo letras minúsculas, números, `-` y `_`. Debe coincidir con el nombre de archivo `<id>.json`; el uso de minúsculas evita colisiones en APFS.
- `name`: de 1 a 120 bytes UTF-8. `author`, si se incluye, también admite hasta 120 bytes.
- El paquete completo puede ocupar hasta 1 MiB y contener hasta 100 comandos.
- `theme.appearance`: `system`, `light` o `dark`. Los colores admiten `#RRGGBB` y `#RRGGBBAA`.
- `layout.interface`: `basic`, `ice`, `terminal`, `office` u `office2D`.
- `layout.sidebarPosition`: `left` o `right`; `workspacePosition`: `right` o `bottom`.
- `sidebarWidth`: 210–400; `workspaceWidth`: 300–1200; `workspaceHeight`: 180–700.
- Los booleanos de layout son `sidebarVisible`, `statusBarVisible` y `explorerVisible`.
- Cada comando contiene `name`, `title`, `kind` y `content`. El nombre es un identificador ASCII de 1–64 bytes, único sin distinguir mayúsculas y minúsculas, y no puede coincidir con un comando integrado de Jack. Los títulos admiten hasta 120 bytes UTF-8. `kind` es `prompt` o `terminal`; el contenido admite hasta 20.000 bytes para prompts y 8.000 para terminal.
- Un prompt sustituye cada marcador `{{args}}` por los argumentos del usuario. El contenido de terminal no interpola argumentos.

Los paquetes se validan antes de guardarse o activarse. Jack limita el tamaño antes de leer cada archivo, rechaza archivos que no sean regulares y no sigue symlinks ni abre FIFO. Una edición inválida conserva la última versión correcta en memoria y muestra el error; si se elimina el archivo, el mod desaparece.

Al activar los mods, Jack conserva su orden. Para cada campo de tema o distribución gana el último valor no omitido; para comandos con el mismo nombre gana el definido por el último mod habilitado. Desactivar y volver a activar un mod lo mueve al final de la prioridad.
