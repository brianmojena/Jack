namespace Jack.Core.Checks;

// Utilidades de disco para las comprobaciones.
internal static class CheckIo
{
    /// <summary>
    /// Borra una carpeta temporal con reintentos. ChatStore guarda en segundo plano (p. ej. al terminar de cargar una
    /// transcripción), así que una escritura puede llegar justo cuando la prueba ya ha terminado.
    /// </summary>
    public static void DeleteDirectory(string path)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
                return;
            }
            catch (Exception error) when (attempt < 20 && error is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(100);
            }
        }
    }
}
