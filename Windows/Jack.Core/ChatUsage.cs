using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Jack.Core;

// Port de Sources/JackCore/ChatUsage.swift, SOLO la parte de Claude Code (decodificación de cuotas de Claude).
// TODO(port): UsageDecoder.codex y UsageDecoder.antigravity (y su lectura por CLI) quedan para Codex y Antigravity.
// TODO(port): ChatUsageService.read para Codex, Antigravity, Stellar, OpenCode y Qoder quedan pendientes; aquí solo Claude.
// Sin credenciales: esta pieza no lee tokens ni el Keychain de macOS. Lee solo el caché de cuota que Claude Code
// guarda en ~/.claude.json (campos cachedUsageUtilization y oauthAccount.accountUuid).

/// <summary>Ejecuta `/usage` en la CLI de Claude para refrescar su caché de cuota (lo hace la CLI con su propia sesión).</summary>
public interface IClaudeUsageRefresher
{
    /// <summary>Actualiza el caché. Es de mejor esfuerzo: los errores no impiden leer el caché existente.</summary>
    Task RefreshAsync(CancellationToken cancellationToken);
}

/// <summary>Decodifica las cuotas de Claude a partir del JSON de Claude Code.</summary>
public static class UsageDecoder
{
    /// <summary>Títulos de las ventanas de cuota de Claude, por su clave.</summary>
    public static IReadOnlyDictionary<string, string> ClaudeWindowTitles { get; } = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["five_hour"] = "5 h",
        ["seven_day"] = "7 d",
        ["seven_day_opus"] = "Opus · 7 d",
        ["seven_day_sonnet"] = "Sonnet · 7 d",
        ["overage"] = "Uso adicional",
    };

    /// <summary>
    /// Lee el caché de `~/.claude.json`. `now` solo se usa en las comprobaciones (por defecto, la hora actual UTC).
    /// Una lectura de menos de 2 minutos se considera fresca; si no, es una última lectura guardada.
    /// </summary>
    public static ProviderUsage ClaudeCache(JsonObject data, DateTime? now = null)
    {
        var cache = ClaudeJsonFields.Obj(data, "cachedUsageUtilization");
        var stamp = ClaudeJsonFields.Num(cache, "fetchedAtMs");
        var limits = ClaudeJsonFields.Obj(cache, "utilization");
        if (cache is null || stamp is null || limits is null)
        {
            return new ProviderUsage
            {
                Provider = ChatProvider.Claude,
                Note = "Claude aún no tiene una lectura local de cuotas. Se actualizará con los eventos de uso de Claude Code.",
                IsCached = true,
            };
        }

        var observed = DateTime.UnixEpoch.AddSeconds(stamp.Value / 1000);
        var cachedAccount = ClaudeJsonFields.Str(cache, "accountUuid");
        var currentAccount = ClaudeJsonFields.Str(ClaudeJsonFields.Obj(data, "oauthAccount"), "accountUuid");
        if (cachedAccount is not null && currentAccount is not null && cachedAccount != currentAccount)
        {
            return new ProviderUsage
            {
                Provider = ChatProvider.Claude,
                Note = "La lectura local pertenece a otra cuenta. Esperando cuotas de la cuenta actual.",
                IsCached = true,
            };
        }

        var windows = new List<UsageWindow>();
        foreach (var key in new[] { "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet" })
        {
            var window = ClaudeJsonFields.Obj(limits, key);
            if (ClaudeJsonFields.Num(window, "utilization") is not { } percent) continue;
            windows.Add(new UsageWindow
            {
                Id = key,
                Title = ClaudeWindowTitles.GetValueOrDefault(key, key),
                UsedPercent = percent,
                ResetsAt = ClaudeJsonFields.Date(ClaudeJsonFields.Get(window, "resets_at")),
                ObservedAt = observed,
            });
        }

        // Los límites semanales de un solo modelo (p. ej. Fable) solo aparecen en la lista `limits`.
        foreach (var limit in ClaudeJsonFields.Objects(ClaudeJsonFields.Get(limits, "limits")))
        {
            if (ClaudeJsonFields.Str(limit, "kind") != "weekly_scoped") continue;
            var model = ClaudeJsonFields.Str(ClaudeJsonFields.Obj(ClaudeJsonFields.Obj(limit, "scope"), "model"), "display_name");
            if (model is null || ClaudeJsonFields.Num(limit, "percent") is not { } scopedPercent) continue;
            var id = "seven_day_" + model.ToLowerInvariant();
            if (windows.Any(existing => existing.Id == id)) continue;
            windows.Add(new UsageWindow
            {
                Id = id,
                Title = model + " · 7 d",
                UsedPercent = scopedPercent,
                ResetsAt = ClaudeJsonFields.Date(ClaudeJsonFields.Get(limit, "resets_at")),
                ObservedAt = observed,
            });
        }

        var current = now ?? DateTime.UtcNow;
        var fresh = current - observed < TimeSpan.FromSeconds(120);
        return new ProviderUsage
        {
            Provider = ChatProvider.Claude,
            Windows = windows,
            Note = fresh
                ? "Cuota de la cuenta compartida con las demás aplicaciones."
                : "Última lectura guardada por Claude Code; no es una consulta en vivo.",
            IsCached = !fresh,
        };
    }

    /// <summary>Decodifica el evento `rate_limit_event` del flujo de Claude Code. Devuelve null si no trae ventanas.</summary>
    public static ProviderUsage? ClaudeEvent(JsonObject data)
    {
        // La versión actual de Claude Code informa todas las ventanas en `unifiedWindows`; el nivel superior solo nombra la que aplica.
        var value = ClaudeJsonFields.Obj(data, "rate_limit_info") ?? ClaudeJsonFields.Obj(data, "rateLimitInfo") ?? data;
        var windows = new List<UsageWindow>();

        if (ClaudeJsonFields.Obj(value, "unifiedWindows") is { } unified)
        {
            foreach (var pair in unified.OrderBy(entry => entry.Key, StringComparer.Ordinal))
            {
                if (ClaudeJsonFields.Num(pair.Value, "utilization") is not { } fraction) continue;
                windows.Add(new UsageWindow
                {
                    Id = pair.Key,
                    Title = ClaudeWindowTitles.GetValueOrDefault(pair.Key, pair.Key),
                    UsedPercent = fraction * 100,
                    ResetsAt = ClaudeJsonFields.Date(ClaudeJsonFields.Get(pair.Value, "resetsAt") ?? ClaudeJsonFields.Get(pair.Value, "resets_at")),
                });
            }
        }

        if ((ClaudeJsonFields.Str(value, "rateLimitType") ?? ClaudeJsonFields.Str(value, "rate_limit_type")) is { } kind
            && windows.All(existing => existing.Id != kind))
        {
            // Una ventana sin porcentaje ocultaría la última lectura conocida; solo se conserva si está agotada.
            double? percent = ClaudeJsonFields.Num(value, "utilization") * 100;
            if (percent is null && ClaudeJsonFields.Str(value, "status") == "rejected") percent = 100;
            if (percent is { } known)
            {
                windows.Add(new UsageWindow
                {
                    Id = kind,
                    Title = ClaudeWindowTitles.GetValueOrDefault(kind, kind),
                    UsedPercent = known,
                    ResetsAt = ClaudeJsonFields.Date(ClaudeJsonFields.Get(value, "resetsAt") ?? ClaudeJsonFields.Get(value, "resets_at")),
                });
            }
        }

        if (windows.Count == 0) return null;
        return new ProviderUsage
        {
            Provider = ChatProvider.Claude,
            Windows = windows,
            Note = "Actualizado por Claude Code.",
        };
    }
}

/// <summary>Lectura de la cuota de Claude para la interfaz. Equivale a la rama `.claude` de ChatUsageService.read.</summary>
public static class ChatUsageService
{
    /// <summary>Ruta de la configuración de Claude Code (%USERPROFILE%\.claude.json). En macOS, Swift usa el home del usuario.</summary>
    public static string DefaultClaudeConfigPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude.json");

    /// <summary>
    /// Refresca (si hay <paramref name="refresher"/>) y lee el caché de cuota de Claude. Sin archivo devuelve la nota de "aún no hay lectura".
    /// TODO(port): la implementación de <see cref="IClaudeUsageRefresher"/> ejecuta `claude --print … /usage`; depende de
    /// ExecutableResolver y StructuredChild (ChatProcess), que aún no están enlazados aquí.
    /// </summary>
    public static async Task<ProviderUsage> ReadClaudeAsync(IClaudeUsageRefresher? refresher = null, string? configPath = null,
        CancellationToken cancellationToken = default)
    {
        if (refresher is not null)
        {
            try
            {
                await refresher.RefreshAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception)
            {
                // Como try? en Swift: si la actualización falla, se usa el caché que haya.
            }
        }

        JsonObject? data = null;
        try
        {
            data = JsonSerializer.Deserialize<JsonNode>(await File.ReadAllBytesAsync(configPath ?? DefaultClaudeConfigPath, cancellationToken)) as JsonObject;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            data = null;
        }
        return UsageDecoder.ClaudeCache(data ?? new JsonObject());
    }
}
