using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Jack.Core;

// Port de Sources/JackCore/ChatStore.swift (modo Normal, proveedor Claude Code).
//
// Swift usa @MainActor + ObservableObject/@Published. Aquí la clase es `partial` y se reparte en varios archivos
// (ChatStore.State.cs, ChatStore.Sending.cs, ChatStore.Settings.cs, ChatStore.JackCommands.cs). Este archivo fija las
// reglas de hilos y de notificación de cambios que comparten todos:
//
//  * Todo el estado se lee y se modifica en el hilo de interfaz: el SynchronizationContext que había al crear el store
//    (en WinUI, el del DispatcherQueue; en las comprobaciones, null y se ejecuta en línea).
//  * Los callbacks de los drivers llegan desde otros hilos: SIEMPRE se reenvían con `RunOnUi(...)` antes de tocar estado.
//  * Tras cambiar una propiedad observable (equivalente a un @Published), llama a `Notify(nameof(Propiedad))`.
//    `Changed` es una señal gruesa de "algo cambió" para vistas que releen el store entero.
public sealed partial class ChatStore : INotifyPropertyChanged
{
    private readonly SynchronizationContext? _ui = SynchronizationContext.Current;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Señal gruesa: algo del store cambió. Se lanza en el hilo de interfaz.</summary>
    public event Action? Changed;

    /// <summary>Notifica el cambio de una propiedad observable (@Published de Swift). Solo en el hilo de interfaz.</summary>
    private void Notify([CallerMemberName] string? property = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
        Changed?.Invoke();
    }

    /// <summary>Ejecuta `action` en el hilo de interfaz: en línea si ya estamos en él o no hay contexto; si no, lo encola.</summary>
    private void RunOnUi(Action action)
    {
        if (_ui == null || SynchronizationContext.Current == _ui) action();
        else _ui.Post(_ => action(), null);
    }
}
