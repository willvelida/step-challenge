CREATE TABLE IF NOT EXISTS participants (
    id TEXT PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9-]{1,20}$'),
    name TEXT NOT NULL,
    team TEXT,
    target INTEGER NOT NULL,
    challenge BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS step_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participant_id TEXT NOT NULL REFERENCES participants(id),
    steps INTEGER NOT NULL CHECK (steps >= 0),
    log_date DATE NOT NULL,
    logged_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_step_logs_participant ON step_logs (participant_id);

CREATE TABLE IF NOT EXISTS daily_targets (
    day_number INTEGER PRIMARY KEY,
    date DATE NOT NULL UNIQUE,
    daily_target INTEGER NOT NULL CHECK (daily_target >= 0),
    cumulative_target INTEGER NOT NULL CHECK (cumulative_target >= 0)
);

CREATE TABLE IF NOT EXISTS challenge_state (
    id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    today DATE NOT NULL,
    day_number INTEGER NOT NULL,
    daily_target INTEGER NOT NULL,
    cumulative_target INTEGER NOT NULL
);

ALTER TABLE challenge_state REPLICA IDENTITY FULL;