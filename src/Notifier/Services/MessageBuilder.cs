using StepChallenge.Notifier.Models;

namespace StepChallenge.Notifier.Services;

public sealed class MessageBuilder : IMessageBuilder
{
    public string? Build(ContestEvent contestEvent)
    {
        var queryId = contestEvent.Payload.Source.QueryId;

        // "i" (added) carries the row in `after`; "d" (removed) carries it in `before`.
        var result = contestEvent.Op switch
        {
            "i" => contestEvent.Payload.After,
            "d" => contestEvent.Payload.Before,
            _ => null   // ignore "u" (updated) and "x" (control)
        };
        if (result is null) return null;

        return (contestEvent.Op, queryId) switch
        {
            ("i", "race-to-goal")  => $"🏁 **{result.Name}** crossed the finish line — {result.Total:N0} steps!",
            ("i", "daily-smashed") => $"💪 **{result.Name}** smashed today's goal ({result.Total:N0} steps).",
            ("i", "behind-pace")   => $"😟 **{result.Name}** has fallen behind pace.",
            ("d", "behind-pace")   => $"😅 **{result.Name}** caught back up to pace.",
            _ => null
        };
    }
}