using System.Text.Json.Serialization;

namespace StepChallenge.Notifier.Models;

public sealed record ContestEvent(
    [property: JsonPropertyName("op")] string Op,
    [property: JsonPropertyName("payload")] ContestPayload Payload);

public sealed record ContestPayload(
    [property: JsonPropertyName("source")] ContestSource Source,
    [property: JsonPropertyName("before")] ContestResult? Before,
    [property: JsonPropertyName("after")] ContestResult? After);

public sealed record ContestSource(
    [property: JsonPropertyName("queryId")] string QueryId);

public sealed record ContestResult(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("total")] double Total,
    [property: JsonPropertyName("target")] double? Target);