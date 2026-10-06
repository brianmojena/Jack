# Jack

Chat nativo y compacto para gestionar varios agentes de desarrollo en macOS. Interfaz oscura en SwiftUI/AppKit, con proyectos, conversaciones independientes, herramientas plegables y permisos dentro del chat.

## Construir

Requiere un Mac con Apple Silicon, macOS 15+, Xcode y XcodeGen. No necesita Electron, Node para la interfaz ni dependencias externas de Swift.

```sh
./scripts/build-app.sh
swift test
```

La aplicación queda en `build/Build/Products/Release/Jack.app`. Es una compilación local con firma ad hoc.

## Uso

Pulsa **Nuevo agente**, elige la carpeta y el proveedor: Codex, Claude Code u OpenCode. Cada conversación guarda su modelo, razonamiento y sesión. Usa **Enter** para enviar y **Shift+Enter** para insertar un salto de línea. El chat muestra el razonamiento o resumen que expone cada proveedor, herramientas con entradas y resultados, comandos con salida en streaming y cambios de archivos con diff. Una franja de actividad indica qué está haciendo el agente. Las herramientas se muestran como actividades expandibles; los permisos requieren una respuesta explícita. Puedes cambiar de conversación mientras otros agentes trabajan.

Cambia de modelo desde el selector en la esquina inferior izquierda del cuadro de mensaje, y ajusta el esfuerzo en el menú contiguo. Codex usa su catálogo local de modelos; Claude ofrece Fable, Opus, Sonnet y Haiku, con esfuerzo de Bajo a Máximo (Haiku no admite esfuerzo); OpenCode muestra los modelos de tus proveedores conectados, agrupados por proveedor, y permite actualizar el catálogo. **Otro modelo…** permite introducir uno nuevo. Los últimos ocho modelos se recuerdan por proveedor. El cambio se aplica al siguiente mensaje y conserva el historial y la sesión; está disponible cuando el agente termina o se detiene. El selector no realiza llamadas de inferencia. OpenCode ofrece las variantes de esfuerzo que admite cada modelo; Automático utiliza su configuración habitual. El menú de modo permite elegir Normal, Plan o Auto en Codex; Manual, Plan, Auto, Aceptar ediciones o Sin preguntas en Claude; y los modos primarios configurados en OpenCode, como Build y Plan. Auto en Codex ejecuta dentro del sandbox del proyecto y deniega las operaciones que requerirían aprobación; Auto en Claude depende de la disponibilidad que indique su CLI. Las preguntas de planificación de Codex se responden dentro del chat.

### Claude Code

Claude Code funciona en Jack como en su terminal:

- **Sesión abierta.** El proceso sigue vivo entre mensajes, así que el siguiente empieza al instante. Los subagentes y comandos en segundo plano siguen trabajando después de la respuesta; al terminar, Claude informa en un turno propio. Una sesión inactiva se cierra pasados unos minutos (**Ajustes → Agentes**; ocupa unos 350 MB) y el siguiente mensaje la reanuda. Nunca se cierra mientras tenga tareas en segundo plano. Los agentes delegados se cierran al terminar.
- **Escribir mientras trabaja.** El mensaje se suma al turno en curso. Si hay un permiso pendiente, lo rechaza y le dice qué hacer en su lugar. **⌘.** interrumpe el turno sin cerrar la sesión.
- **Permisos.** Cada petición se previsualiza como en el chat: el comando o el diff de la edición. Ofrece **Permitir siempre** con la regla que propone Claude Code (⌥⌘↩).
- **Plan y preguntas.** El plan se revisa en Markdown, con *Sí, y aceptar las ediciones*, *Sí, revisando cada edición* o *No, seguir planificando*. Las preguntas de `AskUserQuestion`, de una o varias opciones, se responden en el chat.
- **Modos.** **⇧⇥** cambia entre Manual, Aceptar ediciones y Plan, también a mitad de turno. El selector refleja los cambios que hace el propio Claude, como salir del modo plan.
- **Subagentes y tareas.** Cada subagente agrupa sus herramientas bajo su fila. La lista de tareas (`TaskCreate`/`TaskUpdate`) se ve en vivo sobre el cuadro de mensaje.
- **Terminal ↔ Jack.** **Archivo → Retomar sesión de Claude Code…** (⇧⌘R) abre en Jack cualquier sesión empezada en la terminal, con su historial. En la barra lateral, **Continuar en la terminal** abre `claude --resume` en la terminal del agente, y **Actualizar desde Claude Code** relee la sesión al volver.

Escribe `/` en el cuadro de mensaje para ver los comandos del agente: los integrados, como `/compact`, y sus skills o comandos personalizados. Las flechas eligen, Tab o Enter completan y Esc cierra la lista. Claude Code ejecuta sus propios comandos; en Codex, `/compact` y `/review` usan sus funciones nativas y las skills se invocan por nombre; en OpenCode se ejecutan sus comandos, y `/compact` resume la sesión. La lista se lee del proveedor la primera vez que escribes `/` en cada proyecto, sin gastar tokens.

La barra superior muestra cuánto ocupa la ventana de contexto tras la última petición; el coste estimado aparece al pasar el puntero.

El botón **Carpetas** de la barra superior da acceso a carpetas fuera del proyecto. Cada agente las recibe desde su siguiente mensaje: Claude Code con `--add-dir`, Codex como raíces escribibles de su sandbox y OpenCode como permiso `external_directory`.

Para adjuntar archivos, arrástralos (imágenes, documentos, carpetas…) a cualquier parte del chat o usa el clip del compositor. Todos los agentes reciben la ruta de cada adjunto y acceso de lectura a su carpeta; las imágenes PNG, JPEG, GIF y WebP de hasta 3,75 MB viajan además dentro del mensaje. Las capturas y datos de imagen sin archivo propio se guardan en `~/Library/Application Support/Jack/Attachments`.

Cada agente tiene además un terminal y un navegador propios en el panel lateral: botones **Terminal** y **Navegador** de la barra superior, o ⌃` y ⇧⌘B. El terminal (SwiftTerm) abre tu shell de inicio de sesión en la carpeta del proyecto y sigue vivo al cambiar de agente. El navegador (WebKit) entiende `3000` o `localhost:5173` como servidores locales, incluye el inspector web (clic derecho → Inspeccionar elemento) y recibe los enlaces que pulses en el terminal.

El valor inicial es cuatro conversaciones a la vez. Puedes cambiarlo desde el menú de paralelismo de la barra lateral o en Ajustes: de 1 a 64, o sin límite. Las conversaciones que exceden el valor elegido esperan en cola. Reducirlo no interrumpe las que ya están trabajando. **Detener** interrumpe únicamente la conversación indicada. Al salir se detienen los procesos creados por Jack; el historial guardado permite continuar después. Las sesiones existentes de Herdr siguen siendo independientes.

Instala y autentica los proveedores con sus propias CLI antes de usarlos. Jack aprovecha esos accesos existentes; no administra credenciales ni cuentas. Los nombres de modelos dependen de tu proveedor y acceso. OpenCode usa el formato `proveedor/modelo`, o su modelo configurado si dejas el campo vacío.

## Consumo y persistencia

La interfaz no renderiza terminales. Los proveedores se inician bajo demanda y se liberan al terminar. El texto en streaming se agrupa cada 50 ms. El paralelismo es configurable. Los historiales inactivos quedan en disco; solo las conversaciones seleccionadas, activas o en cola permanecen cargadas. Las herramientas tienen un límite de detalle de 64 KiB.

Los chats se guardan localmente en `~/Library/Application Support/Jack/Chats`: un índice pequeño y un archivo por conversación. El proveedor mantiene también su sesión original para reanudar el contexto. El consumo de inferencia y de las CLI se suma al de la interfaz.

## Uso restante

**Uso y límites**, en la barra lateral, muestra porcentajes restantes por ventana, reinicios y fecha de lectura. Actualizar consulta metadatos sin enviar mensajes a los modelos.

- Codex: consulta oficial `account/rateLimits/read` y actualizaciones del App Server; separa las cuotas de distintos modelos cuando la cuenta las devuelve.
- Claude Code: lectura de `cachedUsageUtilization` en su estado local, identificada como caché con fecha; los eventos nativos `rate_limit_event` actualizan las ventanas disponibles. Los periodos vencidos no se presentan como un saldo nuevo.
- OpenCode: su servidor no expone una cuota unificada para todas las cuentas de sus proveedores. El chat muestra los tokens y el coste que devuelve el agente y el panel identifica la ausencia de cuota.

La app muestra solo el razonamiento que el proveedor envía: no reconstruye contenido oculto. La consulta y caché de cuotas no almacenan credenciales en Jack.

## Arquitectura

- `ChatModels`: contrato de conversaciones, mensajes, herramientas y aprobaciones.
- `ChatStore`: cola, selección, agrupación de eventos y estados.
- `ChatArchive`: índice y transcripciones, escrituras atómicas en cola de utilidad.
- `ChatDrivers` y `ChatProcess`: protocolos estructurados y procesos propios.
- `Sources/Jack`: interfaz nativa, sin emulador de terminal.

Codex usa [App Server](https://learn.chatgpt.com/docs/app-server) por stdio; Claude Code usa [stream-json](https://code.claude.com/docs/en/headless); OpenCode usa su [servidor local](https://dev.opencode.ai/docs/server/). El módulo antiguo de Herdr se conserva con sus pruebas para compatibilidad y el probe de lectura; la nueva interfaz no se conecta a él.

`JackChatProbe` comprueba respuesta estructurada y reanudación real con dos mensajes pequeños. Requiere autenticación y consume uso del proveedor:

```sh
swift run JackChatProbe codex /ruta/proyecto gpt-6-luna
swift run JackChatProbe claude /ruta/proyecto sonnet
swift run JackChatProbe opencode /ruta/proyecto proveedor/modelo
```

La validación y las medidas de esta versión están en [VALIDATION.md](VALIDATION.md).

## Comandos personalizados de Jack

Escribe `!` en el cuadro de mensaje para ver sugerencias; Tab completa, Enter envía y Shift+Enter inserta un salto de línea. Los comandos `/` siguen perteneciendo al proveedor. Usa `!!` para enviar un signo de exclamación literal al comienzo del mensaje. Ejecuta comandos `!` entre turnos, sin archivos adjuntos.

| Comando | Acción |
| --- | --- |
| `!compact 8000` | Genera un resumen hacia un objetivo aproximado y continúa en una sesión nueva. Conserva el historial visible. |
| `!autocompact 30000 8000` | Compacta antes del siguiente mensaje cuando el proveedor informa al menos 30000 tokens de contexto. `off` lo desactiva. |
| `!contexto` | Muestra contexto reportado o una estimación identificada, instrucciones fijadas y presupuesto. |
| `!fijar texto` | Conserva una instrucción al continuar o compactar. `listar` y `quitar número` permiten gestionarlas. |
| `!resumen` | Pide un resumen de avances, decisiones y pendientes. |
| `!checkpoint nombre` | Guarda una copia local de la conversación. `restaurar nombre` abre una copia independiente; no restaura archivos del proyecto. |
| `!rama nombre` | Abre una conversación independiente con contexto del historial actual. |
| `!traspasar` | Genera un resumen de traspaso. Añade `codex`, `claude` u `opencode` para abrir una conversación con ese proveedor y su modelo predeterminado. |
| `!plan tarea` | Activa el modo Plan del proveedor y pide un plan de la tarea. |
| `!revisar` | Pide revisar cambios sin editar archivos. |
| `!presupuesto 20000` | Inicia un presupuesto aproximado desde cero y avisa al 80 %. No detiene la ejecución. `off` lo desactiva. |
| `!comandos` | Lista comandos y plantillas personales. |

Crea una plantilla con `!comandos crear mi-comando instrucciones {{args}}` y úsala con `!mi-comando argumentos`. Repetir el nombre actualiza su plantilla; `!comandos eliminar mi-comando` la elimina. Las plantillas son globales a Jack y se guardan en `Chats/commands.json`; inicialmente se incluyen `!revisar-pr`, `!documentar` y `!preparar-release`.

La compactación y los resúmenes consumen uso del modelo. El objetivo de tokens no es un límite exacto: Jack estima el tamaño del resumen a partir de bytes UTF-8, y las instrucciones y herramientas del proveedor también ocupan contexto. Autocompact requiere datos de contexto del proveedor; si faltan, no dispara por estimaciones. Una compactación cancelada o fallida mantiene la sesión anterior y muestra el mensaje pendiente para reenviarlo. Los checkpoints se conservan localmente en `Chats/Checkpoints`.
