CREATE TABLE participants (
    id TEXT PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9-]{1,20}$'),
    name TEXT NOT NULL,
    team TEXT,
    target INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE step_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participant_id TEXT NOT NULL REFERENCES participants(id),
    steps INTEGER NOT NULL CHECK (steps >= 0),
    log_date DATE NOT NULL,
    logged_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_step_logs_participant ON step_logs (participant_id);