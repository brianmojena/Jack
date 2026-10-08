# Jack

Chat nativo y compacto para gestionar varios agentes de desarrollo en macOS. Interfaz oscura en SwiftUI/AppKit, con proyectos, conversaciones independientes, herramientas plegables y permisos dentro del chat.

## Versionado

La versión actual es **0.3.41**. Las siguientes versiones avanzan dentro de la serie **0.3**, hasta **0.3.99**. El salto a **0.4** por un cambio grande se hará únicamente cuando el usuario lo indique explícitamente.

## Construir

Requiere un Mac con Apple Silicon, macOS 15+, Xcode y XcodeGen. No necesita Electron, Node para la interfaz ni dependencias externas de Swift.

```sh
./scripts/build-app.sh
swift test
```

La aplicación queda en `build/Build/Products/Release/Jack.app`. Es una compilación local con firma ad hoc.

El icono de la aplicación está en `Resources/AppIcon.icon`, en el formato por capas de Icon Composer. Conserva el logo original de Jack, con los brazos traseros, el núcleo frontal y el nodo naranja en capas SVG independientes. Xcode compila el icono Liquid Glass y genera también el icono compatible con versiones anteriores de macOS. `Resources/Logo/jack-icon.svg` conserva el diseño original como referencia.

Para reinstalar la compilación, usa `python3 scripts/install-app.py` con acceso a Aplicaciones. El instalador conserva la carpeta `/Applications/Jack.app` y sustituye únicamente su contenido, guarda la copia anterior, comprueba la firma y todos los archivos, y restaura la copia anterior si falla la sustitución. Actualiza únicamente el acceso de Jack que ya exista en el Dock y refresca el Dock. No abre ni reinicia Jack. Las pruebas del instalador se ejecutan con `python3 scripts/test_install_app.py`, después de compilar.

## Actualizaciones

En modo Normal, Jack consulta las releases de GitHub (`brianmojena/Jack`) al abrirse y cada 6 horas. Si hay una versión más nueva que la instalada, lo avisa en la barra de estado; desde ahí se leen las notas, se instala o se omite esa versión. Ajustes > General permite desactivar la comprobación o buscar al momento. El modo Light nunca comprueba.

**Instalar y reiniciar** descarga el zip, comprueba el tamaño, la firma, el identificador y la versión, y lo descomprime en `~/Library/Application Support/Jack/Updates`. Después Jack se cierra y un script auxiliar (`replace-app.sh`, ya fuera de Jack) espera a que termine, sustituye el contenido de `Jack.app` conservando la carpeta (el Dock no pierde el icono) y abre la nueva versión. La versión anterior queda en `Updates/previous` y, si la sustitución falla, se restaura sola. El registro está en `Updates/update.log`. Si hay agentes trabajando, el aviso lo dice antes de instalar: se detienen al reiniciar. Solo se reemplaza una app que esté en `/Applications` o `~/Applications` y sea escribible; una compilación de `build/` solo ofrece descargar el zip a Descargas. Jack no instala nada sin que lo pidas.

Para publicar una versión: sube `CFBundleShortVersionString` y `CFBundleVersion` en `Resources/Info.plist`, haz commit y push, y ejecuta `scripts/release.sh --publish`. Sin `--publish` solo genera `build/release/Jack-<versión>.zip`. La app lleva firma ad hoc, así que un zip descargado con el navegador pide clic derecho > Abrir la primera vez; la instalación desde Jack no tiene ese problema porque la descarga no lleva cuarentena.

## Uso

Pulsa **Nuevo agente** o **⌘N** y escribe directamente en el chat. La carpeta se elige siempre de forma automática a partir de lo que pidas; si nombras un proyecto que ya está en Jack, el nuevo agente se añade a su grupo. Antes del primer envío, pulsa el logo para elegir Codex, Claude Code, OpenCode o Stellar Code; después, ese mismo logo abre la ventana de contexto. Si no se identifica el proyecto, el chat pide su nombre o ruta y conserva la tarea mientras lo aclaras. Cada conversación guarda su modelo, razonamiento y sesión. Usa **Enter** para enviar y **Shift+Enter** para insertar un salto de línea; **↑/↓** recorre los mensajes enviados anteriores cuando el cuadro está vacío. El chat muestra el razonamiento o resumen que expone cada proveedor, herramientas con entradas y resultados, comandos con salida en streaming y cambios de archivos con diff. Una franja de actividad indica qué está haciendo el agente. Las herramientas se muestran como actividades expandibles; los permisos requieren una respuesta explícita. Puedes cambiar de conversación mientras otros agentes trabajan.

Cambia de modelo desde el selector en la esquina inferior izquierda del cuadro de mensaje, y ajusta el esfuerzo en el menú contiguo. Codex usa su catálogo local de modelos; Claude ofrece Fable, Opus, Sonnet y Haiku, con esfuerzo de Bajo a Máximo (Haiku no admite esfuerzo); OpenCode muestra los modelos de tus proveedores conectados, agrupados por proveedor, y permite actualizar el catálogo. **Otro modelo…** permite introducir uno nuevo. Los últimos ocho modelos se recuerdan por proveedor. El cambio se aplica al siguiente mensaje y conserva el historial y la sesión; está disponible cuando el agente termina o se detiene. El selector no realiza llamadas de inferencia. OpenCode ofrece las variantes de esfuerzo que admite cada modelo; Automático utiliza su configuración habitual. El menú de modo permite elegir Normal, Plan o Auto en Codex; Manual, Plan, Auto, Aceptar ediciones o Sin preguntas en Claude; y los modos primarios configurados en OpenCode, como Build y Plan. Auto en Codex ejecuta dentro del sandbox del proyecto y deniega las operaciones que requerirían aprobación; Auto en Claude depende de la disponibilidad que indique su CLI. Las preguntas de planificación de Codex se responden dentro del chat.

En modo Normal, los permisos adicionales de Codex muestran el acceso solicitado a red y archivos. Puedes rechazarlos, permitirlos para el turno o permitirlos durante la sesión. Si Codex retira una solicitud, Jack quita el permiso pendiente. **Detener** pide a Codex que interrumpa el turno y espera su confirmación antes de enviar otro mensaje; si no responde en cinco segundos, fuerza el cierre del proceso. Light conserva sus permisos y cancelación anteriores.

El panel **Git** (⇧⌘G) muestra el estado del proyecto, los cambios preparados y pendientes, sus diffs y el historial. Permite preparar archivos, hacer commits, gestionar ramas y sincronizar con el remoto; también puedes pedir al agente que revise los cambios y haga el commit desde el propio panel.

Las pestañas de agentes aprovechan el ancho de la barra superior en Basic e Ice y se comprimen juntas al abrir más chats o estrechar la ventana. Cuando no caben, puedes desplazarlas horizontalmente o elegir cualquiera desde **Todas las pestañas** (⌄). La pestaña seleccionada se mantiene visible al cambiar de agente, abrir o cerrar pestañas y redimensionar.

### Claude Code

Claude Code funciona en Jack como en su terminal:

- **Sesión abierta.** El proceso sigue vivo entre mensajes, así que el siguiente empieza al instante. Los subagentes y comandos en segundo plano siguen trabajando después de la respuesta; al terminar, Claude informa en un turno propio. Una sesión inactiva se cierra pasados unos minutos (**Ajustes → Agentes**; ocupa unos 350 MB) y el siguiente mensaje la reanuda. Nunca se cierra mientras tenga tareas en segundo plano. Los agentes delegados se cierran al terminar.
- **Escribir mientras trabaja.** El mensaje queda *En espera* sobre el cuadro de texto y Claude Code lo lee al terminar el paso en curso; entonces pasa al chat en el punto donde lo leyó. Se puede editar o quitar mientras espera. **⌘↩** interrumpe el paso y hace que lo lea ya. **⌘.** detiene el turno sin cerrar la sesión y devuelve los mensajes en espera al cuadro de texto. Si hay un permiso pendiente, escribir lo rechaza y le dice qué hacer en su lugar. Con Codex y OpenCode los mensajes esperan en Jack y se envían juntos al terminar el turno.
- **Sugerencia siguiente.** Cuando Claude Code propone un mensaje, pulsa **Tab** con el cuadro vacío para usarlo.
- **Permisos.** Cada petición se previsualiza como en el chat: el comando o el diff de la edición. Ofrece **Permitir siempre** con la regla que propone Claude Code (⌥⌘↩).
- **Plan y preguntas.** El plan se revisa en Markdown, con *Sí, y aceptar las ediciones*, *Sí, revisando cada edición* o *No, seguir planificando*. Las preguntas de `AskUserQuestion`, de una o varias opciones, se responden en el chat.
- **Modos.** **⇧⇥** cambia entre Manual, Aceptar ediciones y Plan, también a mitad de turno. El selector refleja los cambios que hace el propio Claude, como salir del modo plan.
- **Subagentes y tareas.** Cada subagente agrupa sus herramientas bajo su fila. La lista de tareas (`TaskCreate`/`TaskUpdate`) se ve en vivo sobre el cuadro de mensaje.
- **Terminal ↔ Jack.** **Archivo → Retomar sesión de Claude Code…** (⇧⌘R) abre en Jack cualquier sesión empezada en la terminal, con su historial. En la barra lateral, **Continuar en la terminal** abre `claude --resume` en la terminal del agente, y **Actualizar desde Claude Code** relee la sesión al volver.

Escribe `/` en el cuadro de mensaje para ver los comandos del agente: los integrados, como `/compact`, y sus skills o comandos personalizados. Las flechas eligen, Tab o Enter completan y Esc cierra la lista. Claude Code ejecuta sus propios comandos; en Codex, `/compact` y `/review` usan sus funciones nativas y las skills se invocan por nombre; en OpenCode se ejecutan sus comandos, y `/compact` resume la sesión. La lista se lee del proveedor la primera vez que escribes `/` en cada proyecto, sin gastar tokens.

En Stellar Code, `/compact` y `/compact N` (solo modo Normal) usan la compactación real de Jack, con un objetivo predeterminado de aproximadamente 2000 tokens; `!compact N` sigue disponible. Para análisis y revisiones, el prompt pide hallazgos, consecuencias, mejoras y evidencia por archivo y línea, y limita las afirmaciones sobre verificaciones a las que realmente se ejecutaron. Lee el `AGENTS.md` de raíz hasta 12 KiB; al leer dentro de subdirectorios entrega instrucciones anidadas con un presupuesto total de 4 KiB y bloquea ediciones si la carga está incompleta o desactualizada. El listado inicial es de una carpeta y hasta 80 entradas; `recursive=true` solicita una exploración recursiva acotada. La estimación de contexto usa bytes UTF-8 divididos por cuatro, incluye instrucciones y definiciones de herramientas, y reserva margen para la respuesta; no equivale al tokenizer del modelo. Si se excede, solo pueden reducirse cuerpos de resultados de herramientas antiguos, con marcador visible; nunca se quitan mensajes de usuario/asistente ni pares de llamadas. Si aun así no cabe, conserva todo y recomienda `/compact`. Las instrucciones anidadas no se descubren automáticamente para comandos de shell arbitrarios; Stellar pide inspeccionarlas antes de ejecutar comandos que actúen en esos ámbitos, pero el cargador de instrucciones no es un sandbox de comandos. En Normal puedes vincular explícitamente un modelo de Ollama Cloud desde el daemon local autenticado con `ollama signin`; no se conecta Jack directamente a Ollama Cloud ni se guardan API keys. Ollama recibe el prompt y los archivos leídos, y el uso puede consumir cuota de tu cuenta. Cloud nunca es la selección automática: se prioriza un modelo local con herramientas. Light mantiene el prompt, el catálogo local, el listado recursivo y el comportamiento anteriores. Estas instrucciones de prompt y controles no miden ni garantizan una mejora de un modelo entrenado.

La pestaña **Diagrama de flujo** permite pedir explícitamente en Normal un diagrama para cualquier pregunta, sin activar el modo Plan. Elige un modelo Ollama Cloud vinculado o usa la pregunta más reciente; Jack envía la pregunta y hasta ocho mensajes visibles recientes (máximo 6 KiB) a través del daemon Ollama local autenticado. No lee archivos ni cambia el modelo, historial o sesión del agente. El resultado se valida como grafo y se dibuja de arriba hacia abajo en la interfaz nativa y en la exportación Mermaid; un plan existente sigue apareciendo como alternativa cuando aún no se genera un diagrama. Light conserva el visor anterior de planes. La generación usa una reparación JSON como máximo y no garantiza que el modelo produzca un resultado válido.

En Normal, el clic derecho sobre el botón **Git** abre **Commit**, **Push** y **Pull**, tanto en Basic como en Ice. Commit genera un mensaje con `gemma4:31b-cloud` mediante el daemon Ollama autenticado y confirma automáticamente lo preparado, o todos los cambios si no hay nada preparado. Se envían un resumen y un diff acotados a Ollama Cloud. Si los cambios que se van a confirmar cambian durante la generación, Jack cancela el commit y pide reintentar. Push conserva el comportamiento existente y Pull usa `--ff-only`.

### Claude Code remoto por SSH

Un agente de Claude Code puede correr en otra máquina (modo Normal): pulsa **Nuevo agente**, elige Claude y activa el botón servidor del compositor para indicar el destino (`ruben@192.168.1.193`) y el puerto si hace falta, con **Probar conexión** para comprobar el acceso y que `claude` exista allí. El destino se recuerda para la próxima vez. La carpeta no hace falta indicarla: Jack descubre los proyectos de la otra máquina (su índice si también usa Jack, si no un escaneo) y elige según lo que pidas, igual que en local; si la sabes, puedes fijarla y se usa tal cual. También puedes cambiar el destino después desde el botón servidor junto a **Carpetas** de ese chat. Requiere acceso por clave SSH sin contraseña (`ssh-copy-id destino`) y `claude` instalado en remoto; la primera conexión acepta la clave del host. Jack ejecuta `claude` por SSH con su entrada/salida redirigida, así que el protocolo, los permisos, el modo Plan y las preguntas funcionan igual, y abre un túnel inverso automático para que el agente remoto use las herramientas de delegación de Jack. La sesión remota se mantiene abierta entre mensajes y se reanuda igual que en local. Las carpetas extra locales (`--add-dir`) y `jack-progress` no aplican en remoto; el modo Light no cambia.

La barra superior muestra cuánto ocupa la ventana de contexto tras la última petición; el coste estimado aparece al pasar el puntero.

El botón **Carpetas** de la barra superior da acceso a carpetas fuera del proyecto. Cada agente las recibe desde su siguiente mensaje: Claude Code con `--add-dir`, Codex como raíces escribibles de su sandbox y OpenCode como permiso `external_directory`.

Para adjuntar archivos, arrástralos (imágenes, documentos, carpetas…) a cualquier parte del chat o usa el clip del compositor. Todos los agentes reciben la ruta de cada adjunto y acceso de lectura a su carpeta; las imágenes PNG, JPEG, GIF y WebP de hasta 3,75 MB viajan además dentro del mensaje. Las capturas y datos de imagen sin archivo propio se guardan en `~/Library/Application Support/Jack/Attachments`.

Cada agente tiene además un terminal y un navegador propios en el panel lateral: botones **Terminal** y **Navegador** de la barra superior, o ⌃` y ⇧⌘B. El terminal (SwiftTerm) abre tu shell de inicio de sesión en la carpeta del proyecto y sigue vivo al cambiar de agente. El navegador (WebKit) entiende `3000` o `localhost:5173` como servidores locales, incluye el inspector web (clic derecho → Inspeccionar elemento) y recibe los enlaces que pulses en el terminal.

El valor inicial es cuatro conversaciones a la vez. Puedes cambiarlo desde el menú de paralelismo de la barra lateral o en Ajustes: de 1 a 64, o sin límite. Las conversaciones que exceden el valor elegido esperan en cola. Reducirlo no interrumpe las que ya están trabajando. **Detener** interrumpe únicamente la conversación indicada. Al salir se detienen los procesos creados por Jack; el historial guardado permite continuar después. Las sesiones existentes de Herdr siguen siendo independientes.

Instala y autentica los proveedores con sus propias CLI antes de usarlos. Jack aprovecha esos accesos existentes; no administra credenciales ni cuentas. Los nombres de modelos dependen de tu proveedor y acceso. OpenCode usa el formato `proveedor/modelo`, o su modelo configurado si dejas el campo vacío.

## Progreso y descargas

Cuando un agente descarga algo o lanza un trabajo largo, Jack muestra una barra de progreso nativa en su chat, encima del cuadro de mensaje, y en **Descargas**, en la barra inferior, donde aparecen las de todos los chats. Cada barra indica el porcentaje, lo hecho y el total, la velocidad y el tiempo restante; **Ver detalles** añade la velocidad media, el tiempo transcurrido, el archivo, el comando y los datos extra que dé el agente. Las tareas lanzadas con `run` se pueden pausar, reanudar y cancelar, y el archivo descargado se muestra en Finder.

Jack se lo indica a cada agente y le da `jack-progress`, que viene dentro de la app:

```sh
jack-progress run --title "Llama 3 8B" --kind download --file llama.gguf -- aria2c -x8 https://…/llama.gguf
jack-progress set --id carga --title "Cargando modelo" --fraction 0.4 --detail "capa 12 de 32" --field "GPU=M3 Max"
jack-progress done --id carga            # o: --failed "sin memoria"
```

`run` ejecuta el comando en un pseudoterminal, conserva su salida y su código de salida, e interpreta el progreso de curl, wget, aria2c, git, rsync, pip, huggingface-cli, ollama y cualquier línea con un porcentaje o un tamaño `hecho/total`. Al agente solo le llega un resumen cada 10 %. `set` y `done` sirven para tareas que el agente sigue por su cuenta. Cada tarea es un JSON en `~/Library/Application Support/Jack/Progress/<chat>/` (variable `JACK_PROGRESS_DIR`), así que un script también puede escribirlo directamente. Las terminadas se borran a los siete días.

## Servidores de los proyectos

**Servidores**, en la barra inferior, lista lo que escucha en un puerto dentro de tus proyectos (`npm run dev`, vite, next, rails…), aunque lo haya lanzado otra sesión de Claude Code, Codex u OpenCode o tú en una terminal: puerto, comando, quién lo inició y desde cuándo. Puedes abrirlo, detenerlo (junto con el `npm run` que lo lanzó) y ver con **ⓘ** su CPU, memoria y procesos. Jack lo lee del sistema con libproc cada tres segundos.

Antes de arrancar un servidor, los agentes ejecutan `jack-servers`, que les dice qué hay ya en marcha para su carpeta; si dos sesiones trabajan en el mismo proyecto, la segunda usa el servidor de la primera en lugar de lanzar otro `npm run dev`.

## Imágenes con Image Playground

Los agentes tienen la herramienta `generate_image` del servidor MCP de Jack para crear imágenes con Image Playground de Apple, con estilo realista por defecto (el modelo nuevo de macOS 27) o animación, ilustración y boceto. El agente escribe el prompt, el tamaño y dónde guardarla (por defecto `generated-images/` en su carpeta). En su chat aparece una tarjeta con un brillo animado y Jack abre Image Playground ya preparado; tú eliges el resultado, se guarda en la ruta pedida y el agente la recibe. Si Image Playground rechaza el prompt o lo cierras sin imagen, el agente prueba con otro, hasta tres veces; **Ahora no** le dice que siga sin ella.

macOS 27 ya no permite generar imágenes sin la ventana de Image Playground (`ImageCreator` está obsoleto y responde `notSupported`), por eso cada imagen necesita tu clic. Requiere Apple Intelligence activado; se puede desactivar en Ajustes → General.

## Consumo y persistencia

### Modo Light

**Regla de desarrollo para todos los agentes:** las nuevas funcionalidades y ampliaciones se implementan únicamente en el modo Normal, salvo que el prompt del usuario solicite explícitamente su implementación en Light. También deben evitarse incorporaciones indirectas a Light mediante componentes o servicios compartidos. La regla completa está en [AGENTS.md](AGENTS.md).

Activa el toggle **Light** de la barra inferior del modo Normal para usar una ventana sencilla orientada al ahorro de batería. En Light, el mismo toggle permanece en la barra inferior y permite volver a Normal. También está disponible **Visualización → Modo Light** (⌃⌘L). Comparte chats, sesiones, borradores y adjuntos con el modo Normal. El chat y el editor usan texto nativo de AppKit. El chat renderiza Markdown directamente con el mismo parser de bloques y de formato inline que Normal: títulos, listas, citas, negritas, enlaces, código y tablas; los mensajes del usuario se conservan literales. Los mensajes sin cambios conservan su formato en una caché acotada al historial visible. El transcript usa TextKit 1 para las tablas nativas y el editor TextKit 2. No muestra thinking ni filas de herramientas. **Actividad** abre los comandos ejecutados y su salida, y **Comandos** permite insertar comandos `/` del proveedor y `!` de Jack. Los permisos, preguntas y mensajes en espera siguen disponibles.

El menú **⋯** abre modelo y carpetas, límites, archivos, progreso, servidores y una lectura del texto con formato. Las cuotas se consultan al pulsar **Actualizar**; progreso y servidores se leen al abrir su panel o actualizarlo. Light no mantiene sus consultas periódicas. El texto visible se agrupa cada 1 segundo; los permisos y el cierre del turno vacían el texto pendiente inmediatamente. Los detalles ocultos quedan pendientes hasta que se solicitan, llega texto visible o termina el turno. Una ventana minimizada o completamente tapada suspende las actualizaciones visuales y recupera el texto al volver. Hay notificaciones al terminar, fallar o necesitar respuesta mientras estás fuera.

Light tiene su propio paralelismo, inicialmente un agente. Al activarlo, los agentes que ya trabajan siguen; los siguientes esperan según ese límite. Claude conserva hasta 30 segundos una sesión inactiva, respetando un cierre más corto configurado y sin cerrar tareas de fondo o mensajes pendientes. **Volver al modo Normal** recupera su interfaz, cadencia y configuración habituales. Los navegadores, terminales y simuladores que ya estaban abiertos pueden seguir consumiendo recursos: Light no termina esos procesos automáticamente.

Estas medidas reducen trabajo de la aplicación; no representan todavía una medición del ahorro de batería.

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
- `ProgressTasks` y `ProgressMonitor`: tareas con progreso, lectura de la salida de cada herramienta y seguimiento de las carpetas.
- `ServerScanner`: servidores locales por proyecto, con libproc.
- `Sources/JackProgress`: `jack-progress` (y `jack-servers`), el ayudante que usan los agentes.
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

### Reducir consumo de Claude en Normal

Las sesiones nuevas de Claude empiezan con esfuerzo **medio**; puedes cambiarlo en el selector. Las sesiones existentes conservan su esfuerzo. Normal desactiva las sugerencias automáticas de Claude, también para agentes remotos y subagentes.

Para cambiar de tarea, pulsa el logo del proveedor en el compositor y elige **Nueva tarea sin contexto**. Se abre una sesión vacía en el mismo proyecto con el modelo y esfuerzo actuales, conservando la conversación anterior. No se copian historial, resúmenes ni instrucciones fijadas con `!fijar`. Para continuar la misma tarea puedes seguir usando **Compactar**, que genera un resumen mediante el proveedor y también consume cuota.

Las preguntas al margen de Claude en Normal (`⌥Enter`) usan **Haiku** en una consulta independiente sin herramientas, con hasta 12 000 caracteres de mensajes recientes visibles. No incluyen salidas de herramientas ni razonamiento; pueden faltar decisiones antiguas. La pregunta admite hasta 8000 caracteres. Si Haiku falla, se muestra el error sin volver a consultar al modelo principal. Light conserva su comportamiento anterior.

### Interfaz Terminal (Normal)

En **Ajustes → General → Apariencia → Interfaz**, elige **Terminal**. Inspirada en la organización de [Orca ADE](https://www.onorca.dev/), mantiene la barra lateral por proyectos y ofrece pestañas y una división de dos terminales. Al abrirla por primera vez, aparecen las sesiones locales de Claude ya guardadas en los chats de Jack, sin arrancar procesos. Puedes crear una terminal de Claude Code o un shell libre en una carpeta, renombrarlos, buscar y retomarlos desde la sidebar. `⌘N` abre Claude en el proyecto seleccionado; `⌘W` cierra la terminal con confirmación si sigue abierta; **Control + acento grave** crea un shell libre; `⌥⌘↑/↓` cambia de terminal.

Claude Code se ejecuta de forma interactiva en un PTY de SwiftTerm, directamente con su ejecutable configurado: sin `--print`, driver de chat, historial reenviado, instrucciones añadidas ni servidor MCP de Jack. Empieza con esfuerzo medio y sugerencias desactivadas; el modelo y la autenticación los gestiona el propio CLI. Los permisos y las preguntas se contestan dentro de su interfaz nativa. Otros agentes pueden ejecutarse manualmente en un shell libre.

Jack guarda únicamente nombres, carpetas, selección e identificadores de sesión. Claude conserva sus propios registros y se reanuda cuando existe su transcript. Al reiniciar la app, las entradas se restauran sin ejecutar comandos automáticamente; pulsa **Abrir Claude Code** o **Abrir terminal** para continuar. El scrollback de los shells libres no se guarda. Las terminales permanecen abiertas al cambiar de pestaña o de interfaz en Normal. Una sesión transferida no puede recibir mensajes en el chat al mismo tiempo: termina el proceso de su terminal para devolverla al chat. No se transfieren agentes con trabajo pendiente. Las terminales de esta interfaz se terminan al activar Light o salir de Jack; Light mantiene su interfaz anterior.

La interfaz Terminal no proporciona los paneles de navegador, simulador ni Git del chat. Puedes usar esas herramientas en Basic/Ice o ejecutar sus comandos desde el shell. Usar el CLI directamente elimina la integración de chat, pero no garantiza un porcentaje de ahorro: Claude sigue contando modelo, contexto, herramientas y respuestas contra la cuota.
