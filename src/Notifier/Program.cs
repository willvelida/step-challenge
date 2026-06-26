using StepChallenge.Notifier.Models;
using StepChallenge.Notifier.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddDaprClient();
builder.Services.AddSingleton<IMessageBuilder, MessageBuilder>();
builder.Services.AddSingleton<DiscordNotifier>();
builder.Services.AddSingleton<IDiscordNotifier>(serviceProvider =>
    new RateLimitedDiscordNotifier(
        serviceProvider.GetRequiredService<DiscordNotifier>(),
        serviceProvider.GetRequiredService<ILogger<RateLimitedDiscordNotifier>>()));
builder.Services.AddSingleton<ILeaderTracker, LeaderTracker>();

var app = builder.Build();

app.UseCloudEvents();
app.MapSubscribeHandler();

app.MapPost("/stepup-events", async (
    ContestEvent contestEvent,
    IMessageBuilder messageBuilder,
    ILeaderTracker leaderTracker,
    IDiscordNotifier discord,
    ILogger<Program> logger,
    CancellationToken cancellationToken) =>
{
        logger.LogInformation("Received op={Op} query={QueryId} before={HasBefore} after={HasAfter}",
        contestEvent.Op,
        contestEvent.Payload.Source.QueryId,
        contestEvent.Payload.Before is not null,
        contestEvent.Payload.After is not null);

    var message = contestEvent.Payload.Source.QueryId == "new-leader"
        ? leaderTracker.Handle(contestEvent)
        : messageBuilder.Build(contestEvent);

    if (message is null) return Results.Ok();

    await discord.SendAsync(message, cancellationToken);
    logger.LogInformation("Posted to Discord: {Message}", message);
    return Results.Ok();
}).WithTopic("stepup-pubsub", "stepup-events");

app.Run();