# Contrato de implementación de chat

Las instrucciones para cualquier agente están en [AGENTS.md](AGENTS.md). Las nuevas funcionalidades se aplican solo al modo Normal: no se implementan ni se propagan indirectamente a Light salvo que el prompt del usuario lo pida explícitamente para Light.

La dirección vigente sustituye la UI con terminales por un chat oscuro compacto. SwiftUI/AppKit, macOS14+, sin SwiftTerm ni Electron. Los procesos existentes de Herdr no se modifican.

La conversación identifica proyecto, proveedor, modelo, razonamiento y sesión nativa. Los eventos normalizados son texto incremental o reemplazado por ID, herramientas, aprobaciones, sesión, finalización y error. Cada driver mantiene `run` hasta completar o interrumpir el turno; solo responde a permisos cuando recibe la elección explícita del usuario.

ChatStore permite un límite configurable de 1 a 64 conversaciones o sin límite, con valor inicial de cuatro, agrupa deltas cada50ms, conserva el historial en disco y descarga los chats inactivos. La UI usa listas perezosas y páginas del historial, herramientas expandibles y controles de permiso revisables. Los proveedores se crean bajo demanda; Jack solo detiene sus propios procesos.

Reparto: jack-core implementa drivers y transporte de procesos; jack-ui implementa vistas y aplicación; coordinador implementa modelos, store, archivo, integración, pruebas del store, probe y validación. Ambos agentes de Herdr utilizan Codex GPT-6 Luna con razonamiento high.

La actividad conserva razonamiento expuesto, entrada y salida de herramientas, diffs y metadatos de tokens. Uso y límites separa ventanas y modelos, indica la fecha de lectura y distingue los datos en caché. No se usa control por computadora para la última validación.
