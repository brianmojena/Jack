# Port de Jack a Windows: solo modo Normal

Objetivo: paridad con el modo **Normal** de Jack para Mac (interfaz `MainWindowView` en estilo básico y todas sus funciones), traducido de Swift (`Sources/`) a C# (`Windows/`).

## Fuera de alcance (no migrar)

- Modo Light (`LightWindowView`, `LightNewAgentSheet`, `LightNativeText`, `LightTranscript`).
- Modo Oficina: `Office/`, `Office2D/`, y en JackCore `Office*.swift`.
- Juegos: `Chess*`, `Poker`, `Blackjack`, `LiarGame`, `PlayingCards`.
- Interfaces alternativas: `CodeOS/` (y `CodeOSQuota*`), `TerminalInterfaceView`.
- App móvil y utilidades: `JackMobile`, `JackCtl`, `JackProbe`, `JackChatProbe`, `JackProgress` (binario).
- Funciones exclusivas de Apple sin equivalente en Windows: `SimulatorPanel`/`Simulators`, `ImagePlaygroundViews`, `MacSystemStats`, `BatterySaver` (menú de barra de Mac).

## Fases

1. **Núcleo de datos** (`Jack.Core`, sin UI): modelos de chat, persistencia, Git, worktrees, Markdown, progreso, planes.
2. **Proveedores**: ejecución de CLIs (Codex, Claude Code, OpenCode, Antigravity, Qoder, Stellar), `ChatStore`, aprobaciones, uso y tokens.
3. **Interfaz Normal** (`Jack.WinUI`): ventana principal, barra lateral, transcripción y compositor, aprobaciones, selector de modelo, ajustes.
4. **Paneles**: Git, explorador de archivos, notebook, artefactos, flujo, progreso, programaciones, servidores.
5. **Extras**: personalización, actualizaciones, acceso remoto/SSH, dictado.

## Reglas de traducción

- Una pieza Swift = un archivo C# con el mismo nombre en `Windows/Jack.Core/` (o `Jack.WinUI/` si es vista).
- `Jack.Core` no depende de Windows: debe compilar y probarse con `dotnet run --project Windows/Jack.Core.Checks`.
- Cada pieza añade su propia clase de comprobaciones en `Jack.Core.Checks/` (el coordinador la enlaza en `Program.cs`).
- Lo que dependa de un tipo todavía no portado se marca `// TODO(port): <Tipo> viene de <archivo.swift>`.
- Los agentes no ejecutan `dotnet build` en paralelo (comparten `obj`); compila el coordinador.
