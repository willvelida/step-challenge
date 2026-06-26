using Dapr.Client;

namespace StepChallenge.Notifier.Services;

public sealed class DiscordNotifier(DaprClient daprClient) : IDiscordNotifier
{
    private const string BindingName = "discord";
    private const string Operation = "post";

    public Task SendAsync(string content, CancellationToken cancellationToken)
        => daprClient.InvokeBindingAsync(
            BindingName, Operation, new { content }, cancellationToken: cancellationToken);
}