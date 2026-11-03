## Personalización en Normal — 3 de noviembre de 2026

Implementación de personalización declarativa en modo Normal; todo el código de esta funcionalidad fue escrito por Luna.

- `swift test --build-system native --disable-sandbox --skip-update --cache-path /private/tmp/jack-polish-cache` con el filtro `Customization|ChatCommandTests|LightModeTests|TerminalWorkspaceTests|ClaudeTerminalLifecycleTests|AntigravityTerminalLifecycleTests|PaneLayoutTests`: **43 pruebas, 0 fallos**. Registro: `/private/tmp/jack-customization-tests.log`.
- Revisión del editor renderizado a 720 × 620 y de un cambio anidado de color; el PID de la terminal permaneció constante.
- Se verificaron hot reload por escritura in-place y reemplazo atómico, ausencia de I/O al desactivar y que importar comandos no los ejecuta.
- `project.pbxproj` pasó `plutil lint` y `git diff --check` no reportó problemas.
- Se intentó Release con Xcode y cachés temporales, pero la resolución de dependencias quedó bloqueada por `sandbox-exec` (`sandbox_apply Operation not permitted`). No hay Release confirmado ni app instalada.

## Bandeja, cierres y worktrees — 26 de octubre de 2026

Implementación exclusiva de Normal, escrita con GPT Luna y revisada en integración. La bandeja conserva permisos, fallos y turnos pendientes; los cierres separan ejecuciones registradas de declaraciones del agente; los worktrees permiten revisar e integrar únicamente el commit revisado mediante fast-forward.

- Compilación de desarrollo de la aplicación y sus pruebas con SwiftPM nativo: correcta. Pasaron **116 pruebas**, sin fallos, de ChatStore, cierres, worktrees, integración de Codex, parsers, configuración, comandos, Light y la regresión de seguimiento entre turnos de AgentMentions.
- Se usó `swift test --build-system native --disable-sandbox --skip-update` con cachés y un scratch en `/private/tmp`, reutilizando las dependencias locales. El filtro incluyó `ChatTurnClosureTests|WorktreeServiceTests|ChatStoreTests|CodexIntegrationTests|AgentMentionsTests/testProviderMentionCreatesChildAndBusyReuseReportsJackQueue|LightModeTests|ChatDriversTests|ChatRunConfigurationTests|ChatCommandTests`.
- Las pruebas con Git real cubren aislamiento, rutas con espacios y subdirectorios, cambios de contenido y commits entre capturas, revisión obsoleta, base sucia, errores de estado, historia divergente y cambio a Light. Los drivers simulados usan una captura inyectada para evitar depender de la temporización de procesos Git.
- La suite completa no pudo validarse: las restricciones del entorno impiden abrir sockets y los tests de WebKit no avanzaron. El motor predeterminado también requiere un Metal Toolchain ausente; la compilación nativa anterior sí terminó. No se verificó Release con Xcode ni se realizó una revisión visual manual de los nuevos controles.
- Las capturas pueden incluir cambios concurrentes y no prueban autoría. Las huellas leen metadatos y como máximo el primer MiB. Solo Codex aporta actualmente códigos de salida estructurados al nuevo cierre; una declaración del agente no se presenta como prueba verificada.

# Validación de pestañas — 7 de octubre de 2026

Jack 0.3.20 compila en Release con firma ad hoc verificada. Las vistas reales de pestañas de Basic e Ice se probaron en un proceso aislado con NSHostingView, sin mostrar ventanas ni abrir Jack. Solo se sustituyeron las dependencias del panel de herramientas; las pestañas y el sistema de diseño se compilaron desde los archivos de la aplicación.

- Pasaron 84 distribuciones: 1, 2, 3, 4, 6, 12 y 24 pestañas, con tres anchuras y la barra lateral visible u oculta, en ambos estilos.
- Se verificó que las pestañas que caben no se recortan, que el ancho se comprime de forma uniforme y que cambiar a la primera o la última mantiene visible la selección.
- Pasaron 48 redimensionados con muchas pestañas abiertas. Cuando los controles dejan menos de 100 puntos disponibles, el selector compacto conserva el acceso a todas las pestañas.
- Se inspeccionaron capturas de las vistas aisladas. Las verificaciones no incluyen interacción con la ventana del usuario ni inferencias de los proveedores.

## Validación del chat — 5 de octubre de 2026

La versión vigente usa SwiftUI/AppKit sin SwiftTerm ni dependencias externas de Swift. El proyecto genera una app para arm64, orientada al MacBook Air M1 del usuario.

- 37 pruebas locales pasan sin fallos: historial y descarga de chats inactivos, cola y cambios de paralelismo, streaming agrupado, razonamiento, herramientas y resultados, cuotas separadas por ventana y modelo, lectura de caché con fecha, periodos vencidos y protocolos de transporte. El selector de modelos conserva sesión e historial, bloquea cambios durante una ejecución y persiste los recientes por proveedor.
- La prueba de procesos garantiza que un saludo pequeño se entrega antes de que el hijo termine y que un stderr mayor que la capacidad del pipe no bloquea stdout.
- Compilación Release de Jack.app completada. Las verificaciones de la última iteración son de código y compilación; las pruebas visuales quedan a cargo del usuario, conforme a su instrucción de no usar control por computadora.
- Antes de esa instrucción, Codex, Claude Code y OpenCode pasaron una prueba real de dos mensajes sin herramientas, conservando contexto al reanudar la sesión. La actividad y el panel de cuotas añadidos después se verifican con fixtures locales, sin nuevas inferencias.
- No se midió el consumo de CPU o RAM de esta versión. Las medidas de la antigua UI de terminales no se aplican al nuevo chat.

Codex obtiene las cuotas mediante el protocolo oficial. Claude usa su lectura local guardada y eventos nativos, con fecha visible y comprobación de cuenta cuando existe. OpenCode no devuelve un saldo común para todos sus proveedores; se muestra esa limitación junto al consumo reportado, sin inventar porcentajes.

La app tiene firma ad hoc local, sin notarización. Para probar la compilación actual hay que cerrar y volver a abrir Jack. Cerrar detiene sus propios procesos y guarda las conversaciones; no detiene sesiones de Herdr.

## Modo Light — 7 de octubre de 2026

- `swift test`: 150 pruebas del núcleo y 2 del texto nativo, todas sin fallos. Las nuevas pruebas cubren paralelismo independiente, cambio entre modos con agentes trabajando, detalles diferidos, chats no seleccionados, visibilidad, permisos inmediatos, persistencia y salida de herramientas acotada. Las de AppKit comprueban Unicode, correcciones, adjuntos, carga de historial y selección durante el streaming, sin abrir ventanas ni controlar la app del usuario.
- Compilación Release confirmada con `BUILD SUCCEEDED`; firma local verificada con `codesign --verify --deep --strict`.
- Las vistas del modo Normal no se modificaron. El nuevo selector de modo dirige a un árbol de vistas separado; las políticas de ahorro del núcleo se activan únicamente en Light y se restauran al salir.
- Las pruebas visuales siguen siendo manuales. No se midió todavía el ahorro real de batería. Los procesos de proveedores y las herramientas que ya estaban abiertas pueden seguir consumiendo recursos.

### Markdown visible en Light — 7 de octubre de 2026

- Solicitado explícitamente para Light: el chat muestra Markdown con el parser de bloques de Normal y las mismas opciones de formato inline de `AttributedString`. El renderizado de Normal no se modifica. Se mantienen el filtrado de thinking/herramientas, el agrupado de 250 ms y la suspensión de actualizaciones de ventanas ocultas.
- El texto nativo conserva una caché de mensajes sin cambios, acotada a los mensajes visibles y vaciada al cambiar de conversación. Solo se renderizan de nuevo los mensajes modificados. Las tablas usan `NSTextTable` con TextKit 1 explícito; el editor mantiene TextKit 2.
- `swift test`: 150 pruebas del núcleo y 6 del texto nativo sin fallos. Las nuevas pruebas cubren títulos, estilos inline, enlaces, listas, código literal, celdas y alineación de tablas, cierres/correcciones durante streaming, selección y reutilización de la caché. El layout de una tabla se verifica sin abrir ventanas ni controlar la app.
- Release confirmado con `BUILD SUCCEEDED`; firma local verificada. La revisión visual y la medición del consumo siguen pendientes de comprobación manual.

### Actualizaciones de Light cada segundo — 7 de octubre de 2026

- Por petición explícita, el agrupado de texto de Light pasa de 250 ms a 1 segundo. Normal conserva sus 50 ms. Los permisos, la finalización, el cambio de modo y el regreso a una conversación visible siguen vaciando el texto pendiente inmediatamente.
- `swift test`: 151 pruebas del núcleo y 6 del texto nativo sin fallos. La nueva prueba comprueba que no se publique a los 400 ms, que los fragmentos se acumulen al cumplirse el segundo y que permisos/finalización no esperen al temporizador. Las pruebas existentes de detalles y visibilidad esperan más de un intervalo completo.

### Integración con main 0.3.19 — 7 de octubre de 2026

- Integrados los cambios remotos de 0.3.18 y 0.3.19 antes de publicar Light. El nuevo panel Git y el enrutamiento automático de proyectos permanecen en Normal. Light conserva su formulario anterior, aislado en `LightNewAgentSheet`, y su selección de carpeta mediante el locator existente. Una prueba de regresión verifica que un proyecto conocido no active indirectamente el nuevo enrutamiento en Light.
- `swift test`: 160 pruebas del núcleo y 6 del texto nativo sin fallos. Release confirmado con `BUILD SUCCEEDED` y firma local verificada después de integrar los cambios remotos.
