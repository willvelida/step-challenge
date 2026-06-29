using Npgsql;

namespace StepChallenge.Clock.Data;

public sealed class PostgresChallengeStateRepository(NpgsqlDataSource dataSource)
    : IChallengeStateRepository
{
    private const string AdvanceSql = """
        INSERT INTO challenge_state (id, today, day_number, daily_target, cumulative_target)
        SELECT TRUE, dt.date, dt.day_number, dt.daily_target, dt.cumulative_target
        FROM daily_targets dt
        WHERE dt.day_number = LEAST(
            (SELECT day_number FROM challenge_state) + 1,
            (SELECT max(day_number) FROM daily_targets))
        ON CONFLICT (id) DO UPDATE
            SET today = EXCLUDED.today, day_number = EXCLUDED.day_number,
                daily_target = EXCLUDED.daily_target,
                cumulative_target = EXCLUDED.cumulative_target;
        UPDATE contest_state SET status = 'finished'
            WHERE id AND (SELECT day_number FROM challenge_state) >= (SELECT max(day_number) FROM daily_targets);
        """;

    private const string SetByDateSql = """
        INSERT INTO challenge_state (id, today, day_number, daily_target, cumulative_target)
        SELECT TRUE, date, day_number, daily_target, cumulative_target
        FROM daily_targets WHERE date = @value
        ON CONFLICT (id) DO UPDATE
            SET today = EXCLUDED.today, day_number = EXCLUDED.day_number,
                daily_target = EXCLUDED.daily_target,
                cumulative_target = EXCLUDED.cumulative_target;
        """;

    private const string SetByDaySql = """
        INSERT INTO challenge_state (id, today, day_number, daily_target, cumulative_target)
        SELECT TRUE, date, day_number, daily_target, cumulative_target
        FROM daily_targets WHERE day_number = @value
        ON CONFLICT (id) DO UPDATE
            SET today = EXCLUDED.today, day_number = EXCLUDED.day_number,
                daily_target = EXCLUDED.daily_target,
                cumulative_target = EXCLUDED.cumulative_target;
        """;

    public async Task AdvanceToNextDayAsync(CancellationToken ct = default)
    {
        await using var cmd = dataSource.CreateCommand(AdvanceSql);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public Task<bool> SetDayByDateAsync(DateOnly date, CancellationToken ct = default)
        => ExecuteWithValueAsync(SetByDateSql, date, ct);

    public Task<bool> SetDayAsync(int dayNumber, CancellationToken ct = default)
        => ExecuteWithValueAsync(SetByDaySql, dayNumber, ct);

    private async Task<bool> ExecuteWithValueAsync(string sql, object value, CancellationToken ct)
    {
        await using var cmd = dataSource.CreateCommand(sql);
        cmd.Parameters.AddWithValue("value", value);
        return await cmd.ExecuteNonQueryAsync(ct) > 0;
    }
}