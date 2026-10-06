# Validación del chat — 5 de octubre de 2026

La versión vigente usa SwiftUI/AppKit sin SwiftTerm ni dependencias externas de Swift. El proyecto genera una app para arm64, orientada al MacBook Air M1 del usuario.

- 37 pruebas locales pasan sin fallos: historial y descarga de chats inactivos, cola y cambios de paralelismo, streaming agrupado, razonamiento, herramientas y resultados, cuotas separadas por ventana y modelo, lectura de caché con fecha, periodos vencidos y protocolos de transporte. El selector de modelos conserva sesión e historial, bloquea cambios durante una ejecución y persiste los recientes por proveedor.
- La prueba de procesos garantiza que un saludo pequeño se entrega antes de que el hijo termine y que un stderr mayor que la capacidad del pipe no bloquea stdout.
- Compilación Release de Jack.app completada. Las verificaciones de la última iteración son de código y compilación; las pruebas visuales quedan a cargo del usuario, conforme a su instrucción de no usar control por computadora.
- Antes de esa instrucción, Codex, Claude Code y OpenCode pasaron una prueba real de dos mensajes sin herramientas, conservando contexto al reanudar la sesión. La actividad y el panel de cuotas añadidos después se verifican con fixtures locales, sin nuevas inferencias.
- No se midió el consumo de CPU o RAM de esta versión. Las medidas de la antigua UI de terminales no se aplican al nuevo chat.

Codex obtiene las cuotas mediante el protocolo oficial. Claude usa su lectura local guardada y eventos nativos, con fecha visible y comprobación de cuenta cuando existe. OpenCode no devuelve un saldo común para todos sus proveedores; se muestra esa limitación junto al consumo reportado, sin inventar porcentajes.

La app tiene firma ad hoc local, sin notarización. Para probar la compilación actual hay que cerrar y volver a abrir Jack. Cerrar detiene sus propios procesos y guarda las conversaciones; no detiene sesiones de Herdr.
