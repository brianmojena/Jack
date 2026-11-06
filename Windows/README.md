# Jack para Windows · C# + WinUI 3

Primera base del **modo Normal**, separada de la aplicación Swift. No modifica Jack para macOS ni implementa Light.

Incluye una ventana con controles nativos, selección de carpeta, creación de conversaciones con nombre y proveedor, y selección desde la barra lateral. Las conversaciones viven en memoria y se pierden al cerrar. Codex, Claude Code y OpenCode son opciones de configuración: **todavía no hay conexión con sus CLI**, envío de mensajes ni ejecución de tareas. No lee historiales de Jack ni escribe en las carpetas elegidas.

## Estructura

- `Jack.Core`: modelos y creación validada de conversaciones, sin dependencias de Windows.
- `Jack.WinUI`: interfaz WinUI 3, solo Windows, para ARM64 y x64.
- `Jack.Core.Checks`: comprobaciones ejecutables del núcleo, sin paquetes de pruebas adicionales.

Se requiere el SDK de .NET 10. La interfaz usa una versión estable fijada de Windows App SDK 1.8. La app se configura sin MSIX y lleva los runtimes de .NET y Windows App SDK junto al ejecutable; en esta etapa no necesita certificado de firma ni instalador.

## Probar el núcleo directamente en tu Mac

Instala el [SDK de .NET 10 para macOS Arm64](https://dotnet.microsoft.com/en-us/download/dotnet/10.0). Desde la raíz del repositorio:

```sh
dotnet --version
dotnet run --project Windows/Jack.Core.Checks
```

Este comando comprueba nombres, rutas, proveedores, identidad y orden de las conversaciones, y que rechazar entradas inválidas no cambie el estado. Sale con error si falla una comprobación. No abre una ventana. No compiles la solución completa en macOS: contiene el proyecto WinUI, que requiere las herramientas de Windows.

## Probar la ventana en tu Mac mediante Windows

WinUI 3 no se ejecuta directamente en macOS. En un Mac con Apple Silicon utiliza **Windows 11 ARM**, por ejemplo en Parallels Desktop. Microsoft documenta esta [opción de Windows en Mac](https://support.microsoft.com/en-us/windows/experience/platform-variants/options-for-using-windows-11-with-mac-computers-with-apple-m1-m2-and-m3-chips). Parallels y la licencia de Windows pueden tener coste. También puedes usar un PC Windows remoto.

Dentro de Windows:

1. Instala Visual Studio 2026 con la carga de trabajo **WinUI application development** y el SDK de .NET 10. Sigue la [preparación oficial de Microsoft](https://learn.microsoft.com/en-us/windows/apps/get-started/start-here).
2. Copia o clona este repositorio en una carpeta local de Windows, por ejemplo `C:\src\Jack`.
3. Abre PowerShell en esa carpeta y ejecuta las comprobaciones y la app:

```powershell
dotnet run --project Windows/Jack.Core.Checks
dotnet run --project Windows/Jack.WinUI -p:Platform=ARM64
```

En un PC Windows Intel/AMD, sustituye `ARM64` por `x64`. Para editar en Visual Studio, abre `Windows/Jack.WinUI/Jack.WinUI.csproj` y selecciona la plataforma correspondiente. La primera compilación necesita acceso a NuGet.

Prueba manual de la interfaz:

1. Comprueba el estado inicial y pulsa **Nuevo agente**.
2. Cancela el selector: no debe aparecer una conversación.
3. Elige una carpeta local, escribe un nombre y selecciona un proveedor.
4. Intenta crear con un nombre vacío: el diálogo debe seguir abierto y explicar el problema.
5. Crea dos conversaciones y alterna entre ellas; comprueba sus nombres, proveedores y rutas.
6. Redimensiona la ventana, revisa el foco con Tab y los temas claro/oscuro de Windows.
7. Cierra y vuelve a abrir: la lista debe estar vacía, como advierte el prototipo.

## Estado de validación

Se revisaron los archivos XML y las referencias locales. Las comprobaciones de `Jack.Core.Checks` se compilaron y ejecutaron correctamente con el SDK de .NET 10.0.403 para Windows x64 dentro de CrossOver 26.3. **La app completa todavía no se ha compilado ni validado visualmente en Windows**. Este código es una base inicial, no una versión validada para distribuir.

### Prueba de CrossOver · 6 de noviembre de 2026

Se utilizó una botella Windows 10 x64 independiente en `build/crossover/bottles/Jack-WinUI-Test`, sin modificar las botellas existentes ni el código de la aplicación para adaptar su comportamiento a Wine.

- El SDK de .NET 10.0.403 arrancó y todas las comprobaciones del núcleo pasaron.
- La compilación de Jack se detuvo en XAML con `WMC9999`: Wine Mono falló al cargar los metadatos. El compilador integrado de .NET también falló. Tras instalar .NET Framework 4.8 y probar el cargador CLR nativo, el proceso XAML quedó bloqueado y se detuvo.
- Para comprobar la ejecución de WinUI por separado, se creó una ventana mínima desde C# en `build/crossover/WinUIProbe`, con el mismo Windows App SDK 1.8.260921001. MakePri devolvió `0x80004001` (`Not implemented`); la prueba logró compilarse al desactivar la generación de PRI, al no tener recursos propios.
- Al ejecutar esa prueba, Wine abortó con **`Unimplemented function ntdll.dll.NtCreateWaitCompletionPacket`**, antes de completar `Window.Activate`. No se obtuvo una ventana validada.

**Resultado:** CrossOver 26.3 no permite usar esta configuración como entorno de prueba de WinUI. La prueba mínima no sustituye a la app completa, pero confirma un bloqueo del runtime, además de los problemas de compilación. Esto no demuestra incompatibilidad con todas las versiones futuras de CrossOver. Para avanzar, compilar y validar en Windows real o virtualizado.

Los descargables, la botella, la prueba mínima, los registros y los resultados de compilación se eliminaron después de la prueba a petición del usuario para recuperar espacio (aproximadamente 4,7 GiB). Se conserva aquí el diagnóstico. Los SDK y componentes solo se prepararon para esa prueba, sin instalar .NET en macOS. El acceso visual mediante Computer Use no estaba autorizado en la sesión; el resultado se verificó mediante los registros y códigos de salida.

La siguiente etapa es conectar un proveedor real con su protocolo, permisos y cancelación, y después guardar las conversaciones. No se han añadido dependencias, procesos ni consultas de fondo a la app Swift.
