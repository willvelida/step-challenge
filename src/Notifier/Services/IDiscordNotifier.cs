namespace StepChallenge.Notifier.Services;

public interface IDiscordNotifier
{
    Task SendAsync(string content, CancellationToken cancellationToken);
}