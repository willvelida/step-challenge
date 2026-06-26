using StepChallenge.Notifier.Models;

namespace StepChallenge.Notifier.Services;

public interface ILeaderTracker
{
    string? Handle(ContestEvent contestEvent);
}