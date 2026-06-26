namespace StepChallenge.Notifier.Services;

public sealed class RateLimitedDiscordNotifier(
    DiscordNotifier inner,
    ILogger<RateLimitedDiscordNotifier> logger) : IDiscordNotifier
{
    // An identical message is suppressed if re-sent within this window.
    private static readonly TimeSpan DedupeWindow = TimeSpan.FromSeconds(60);
    // At most MaxPerWindow messages are sent in any RateWindow.
    private static readonly TimeSpan RateWindow = TimeSpan.FromSeconds(10);
    private const int MaxPerWindow = 5;

    private readonly Lock _gate = new();
    private readonly Dictionary<string, DateTimeOffset> _lastSentByContent = [];
    private readonly Queue<DateTimeOffset> _recentSends = new();

    public Task SendAsync(string content, CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;

        lock (_gate)
        {
            // 1. Dedupe — was this exact text sent recently?
            if (_lastSentByContent.TryGetValue(content, out var lastSent) &&
                now - lastSent < DedupeWindow)
            {
                logger.LogInformation("Suppressed duplicate: {Message}", content);
                return Task.CompletedTask;
            }

            // 2. Rate-limit — drop timestamps outside the window, then check the cap.
            while (_recentSends.Count > 0 && now - _recentSends.Peek() > RateWindow)
                _recentSends.Dequeue();

            if (_recentSends.Count >= MaxPerWindow)
            {
                logger.LogWarning("Suppressed (rate limit {Max}/{Seconds}s): {Message}",
                    MaxPerWindow, RateWindow.TotalSeconds, content);
                return Task.CompletedTask;
            }

            _lastSentByContent[content] = now;
            _recentSends.Enqueue(now);
        }

        return inner.SendAsync(content, cancellationToken);
    }
}