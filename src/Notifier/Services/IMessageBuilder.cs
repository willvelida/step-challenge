using StepChallenge.Notifier.Models;

namespace StepChallenge.Notifier.Services;

public interface IMessageBuilder
{
    string? Build(ContestEvent contestEvent);
}