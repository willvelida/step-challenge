using StepChallenge.Notifier.Models;

namespace StepChallenge.Notifier.Services;

public sealed class LeaderTracker : ILeaderTracker
{
    private readonly Dictionary<string, Standing> _standings = [];
    private readonly Lock _gate = new();
    private string? _leaderId;

    public string? Handle(ContestEvent contestEvent)
    {
        lock (_gate)
        {
            Apply(contestEvent);

            var leader = _standings.Values
                .OrderByDescending(standing => standing.Total)
                .ThenBy(standing => standing.Id)   // deterministic tie-break, avoids flapping
                .FirstOrDefault();

            if (leader is null || leader.Id == _leaderId)
                return null;                       // no leader, or unchanged → stay quiet

            _leaderId = leader.Id;
            return $"👑 **{leader.Name}** has taken the lead with {leader.Total:N0} steps!";
        }
    }

    private void Apply(ContestEvent contestEvent)
    {
        switch (contestEvent.Op)
        {
            case "i" or "u" when contestEvent.Payload.After is { } after:
                _standings[after.Id] = new Standing(after.Id, after.Name, after.Total);
                break;
            case "d" when contestEvent.Payload.Before is { } before:
                _standings.Remove(before.Id);
                break;
        }
    }

    private sealed record Standing(string Id, string Name, double Total);
}