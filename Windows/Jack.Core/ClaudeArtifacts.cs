using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Jack.Core;

// Port de Sources/JackCore/ClaudeArtifacts.swift (modo Normal, proveedor Claude Code).
// Metadatos de la galería de artefactos de Claude. No se guardan credenciales aquí.
// TODO(port): ArtifactLibrary.importClaudeArtifact (la extensión de Swift que crea el artefacto local) viene de Artifacts.swift,
// junto con JackArtifact, ArtifactKind y ArtifactError. Pendiente; esta pieza solo decodifica y extrae el contenido.

/// <summary>Metadatos de un artefacto de la galería de Claude.</summary>
public sealed record ClaudeArtifact
{
    [JsonPropertyName("uuid")] public required string Uuid { get; init; }
    [JsonPropertyName("artifact_identifier")] public required string ArtifactIdentifier { get; init; }
    [JsonPropertyName("artifact_type")] public required string ArtifactType { get; init; }
    [JsonPropertyName("title")] public required string Title { get; init; }
    [JsonPropertyName("chat_conversation_uuid")] public required string ChatConversationUuid { get; init; }
    [JsonPropertyName("chat_conversation_name")] public string? ChatConversationName { get; init; }
    [JsonPropertyName("latest_published_artifact_uuid")] public string? LatestPublishedArtifactUuid { get; init; }

    /// <summary>La organización no viene en el JSON: la asigna quien pide la página (en Swift era una `var` con valor por defecto).</summary>
    [JsonIgnore] public string OrganizationId { get; set; } = "";

    [JsonIgnore] public string Id => OrganizationId + ":" + Uuid;

    [JsonIgnore] public string Origin => "Claude:" + OrganizationId + ":" + Uuid;

    /// <summary>Enlace público si el artefacto está publicado; si no, la conversación con el artefacto seleccionado.</summary>
    [JsonIgnore]
    public Uri SourceUrl
    {
        get
        {
            if (LatestPublishedArtifactUuid is { } published && Guid.TryParseExact(published, "D", out _))
            {
                return new Uri("https://claude.ai/public/artifacts/" + published);
            }
            return new Uri($"https://claude.ai/chat/{ChatConversationUuid}?artifact={Uri.EscapeDataString(ArtifactIdentifier)}");
        }
    }
}

/// <summary>Una página de la galería; `next_cursor` indica si hay más.</summary>
public sealed record ClaudeArtifactPage
{
    [JsonPropertyName("artifacts")] public List<ClaudeArtifact> Artifacts { get; set; } = [];
    [JsonPropertyName("next_cursor")] public string? NextCursor { get; init; }
}

/// <summary>Extrae el contenido completo de un artefacto de la conversación de Claude.</summary>
public static class ClaudeArtifactContent
{
    /// <summary>
    /// Solo cuentan los payloads completos de la herramienta `artifacts`; las vistas previas de la galería están truncadas.
    /// Sigue la rama de la conversación que termina en `current_leaf_message_uuid`. Devuelve null si no hay contenido completo.
    /// </summary>
    public static string? Extract(byte[] data, string identifier)
    {
        JsonObject? chat;
        try
        {
            chat = JsonSerializer.Deserialize<JsonNode>(data) as JsonObject;
        }
        catch (JsonException)
        {
            chat = null;
        }
        // TODO(port): en Swift se lanza ArtifactError (de Artifacts.swift); aquí, InvalidOperationException hasta portarlo.
        if (chat is null || ClaudeJsonFields.Get(chat, "chat_messages") is not JsonArray)
        {
            throw new InvalidOperationException("Claude devolvió una conversación con un formato no reconocido.");
        }

        var messages = ClaudeJsonFields.Objects(ClaudeJsonFields.Get(chat, "chat_messages")).ToList();
        var ordered = messages;
        if (ClaudeJsonFields.Str(chat, "current_leaf_message_uuid") is { } leaf)
        {
            var byId = new Dictionary<string, JsonObject>(StringComparer.Ordinal);
            foreach (var message in messages)
            {
                // Como Dictionary(uniquingKeysWith: last) de Swift: gana el último.
                if (ClaudeJsonFields.Str(message, "uuid") is { } messageId) byId[messageId] = message;
            }

            var branch = new List<JsonObject>();
            string? cursor = leaf;
            var seen = new HashSet<string>(StringComparer.Ordinal);
            while (cursor is not null && seen.Add(cursor) && byId.TryGetValue(cursor, out var current))
            {
                branch.Add(current);
                cursor = ClaudeJsonFields.Str(current, "parent_message_uuid");
            }
            if (branch.Count == 0) return null;
            branch.Reverse();
            ordered = branch;
        }

        string? latest = null;
        foreach (var message in ordered)
        {
            foreach (var block in ClaudeJsonFields.Objects(ClaudeJsonFields.Get(message, "content")))
            {
                if (ClaudeJsonFields.Str(block, "type") != "tool_use" || ClaudeJsonFields.Str(block, "name") != "artifacts") continue;
                if (ClaudeJsonFields.Get(block, "input") is not JsonObject input || ClaudeJsonFields.Str(input, "id") != identifier) continue;
                // Las actualizaciones parciales no se pueden importar como documento completo.
                if (ClaudeJsonFields.Str(input, "content") is { } content) latest = content;
                else if (ClaudeJsonFields.Str(input, "command") == "update") latest = null;
            }
        }
        return latest;
    }

    /// <summary>
    /// Nombre del tipo de artefacto según su MIME ("text/html" -> "html", etc.).
    /// TODO(port): en Swift devuelve ArtifactKind (de Artifacts.swift); aquí, el nombre del caso hasta portarlo.
    /// </summary>
    public static string KindName(string mimeType) => mimeType switch
    {
        "text/html" => "html",
        "text/markdown" => "markdown",
        "image/svg+xml" => "svg",
        _ => "code",
    };
}
