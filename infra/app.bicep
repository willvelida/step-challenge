extension radius
extension kubernetes with {
  kubeConfig: ''
  namespace: 'default'
}

@description('Radius-supplied environment ID.')
param environment string

@description('Image tag for the StepUp service images (built + kind-loaded locally).')
param imageTag string = 'local'

@description('Registry/prefix for the service images. Local default "stepup"; for ACR set your login server, e.g. "myregistry.azurecr.io".')
param imageRegistry string = 'stepup'

// The Radius application. Containers (added next) will reference app.id.
resource app 'Applications.Core/applications@2023-10-01-preview' = {
  name: 'stepup'
  properties: {
    environment: environment
  }
}

// ---------------------------------------------------------------------------
// Postgres with logical replication for StepUp + the Drasi source.
// Deployed as raw Kubernetes resources so Radius owns it without a recipe.
// Pinned to Service `postgres` in namespace `default`, so the Drasi source host
// `postgres.default.svc.cluster.local` stays unchanged (drasi/source.yaml).
// ---------------------------------------------------------------------------

// Init SQL, verbatim from data/*.sql. Keys are numbered so Postgres runs them
// in order on first init: schema -> seed -> drasi role.
resource initdb 'core/ConfigMap@v1' = {
  metadata: {
    name: 'stepup-initdb'
    namespace: 'default'
  }
  data: {
    '01-schema.sql': '''
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

CREATE TABLE IF NOT EXISTS contest_state (
    id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    participant_count INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'idle' CHECK (status IN ('idle', 'running', 'finished')),
    started_at TIMESTAMPTZ
);

-- REPLICA IDENTITY FULL makes Postgres include every column (not just the
-- primary key) in the logical-replication record for UPDATEs and DELETEs.
-- Drasi/Debezium requires non-null values for NOT NULL columns (e.g.
-- step_logs.log_date) on DELETE; without FULL, a delete sends nulls and the
-- source connector crashes. Every table the Drasi source reads needs this.
ALTER TABLE participants REPLICA IDENTITY FULL;
ALTER TABLE step_logs REPLICA IDENTITY FULL;
ALTER TABLE daily_targets REPLICA IDENTITY FULL;
ALTER TABLE challenge_state REPLICA IDENTITY FULL;
ALTER TABLE contest_state REPLICA IDENTITY FULL;
'''
    '02-seed.sql': '''
INSERT INTO daily_targets (day_number, date, daily_target, cumulative_target)
SELECT
    d AS day_number,
    DATE '2026-01-01' + (d - 1) AS date,
    10000 AS daily_target,
    10000 * d AS cumulative_target
FROM generate_series(1, 30) AS d
ON CONFLICT (day_number) DO UPDATE
    SET date = EXCLUDED.date,
        daily_target = EXCLUDED.daily_target,
        cumulative_target = EXCLUDED.cumulative_target;

INSERT INTO challenge_state (id, today, day_number, daily_target, cumulative_target)
SELECT TRUE, date, day_number, daily_target, cumulative_target
FROM daily_targets
WHERE day_number = 1
ON CONFLICT (id) DO UPDATE
    SET today = EXCLUDED.today,
        day_number = EXCLUDED.day_number,
        daily_target = EXCLUDED.daily_target,
        cumulative_target = EXCLUDED.cumulative_target;

INSERT INTO contest_state (id, participant_count, status, started_at)
VALUES (TRUE, 0, 'idle', NULL) ON CONFLICT (id) DO NOTHING;
'''
    '03-drasi.sql': '''
CREATE ROLE drasi WITH REPLICATION LOGIN SUPERUSER PASSWORD 'drasi';
'''
  }
}

// Persistent data so the replication slot survives pod restarts. Init scripts
// run only on first init -> `kubectl delete pvc postgres-data` to re-seed.
resource pgData 'core/PersistentVolumeClaim@v1' = {
  metadata: {
    name: 'postgres-data'
    namespace: 'default'
  }
  spec: {
    accessModes: [ 'ReadWriteOnce' ]
    resources: {
      requests: {
        storage: '1Gi'
      }
    }
  }
}

resource postgres 'apps/Deployment@v1' = {
  metadata: {
    name: 'postgres'
    namespace: 'default'
    labels: {
      app: 'postgres'
    }
  }
  spec: {
    replicas: 1
    selector: {
      matchLabels: {
        app: 'postgres'
      }
    }
    template: {
      metadata: {
        labels: {
          app: 'postgres'
        }
      }
      spec: {
        containers: [
          {
            name: 'postgres'
            image: 'postgres:16'
            args: [ '-c', 'wal_level=logical', '-c', 'max_replication_slots=10', '-c', 'max_wal_senders=10' ]
            env: [
              { name: 'POSTGRES_PASSWORD', value: 'postgres' }
              { name: 'POSTGRES_DB', value: 'stepup' }
              { name: 'PGDATA', value: '/var/lib/postgresql/data/pgdata' }
            ]
            ports: [
              { containerPort: 5432 }
            ]
            volumeMounts: [
              { name: 'initdb', mountPath: '/docker-entrypoint-initdb.d' }
              { name: 'data', mountPath: '/var/lib/postgresql/data' }
            ]
          }
        ]
        volumes: [
          {
            name: 'initdb'
            configMap: {
              name: 'stepup-initdb'
            }
          }
          {
            name: 'data'
            persistentVolumeClaim: {
              claimName: 'postgres-data'
            }
          }
        ]
      }
    }
  }
}

resource postgresSvc 'core/Service@v1' = {
  metadata: {
    name: 'postgres'
    namespace: 'default'
    labels: {
      app: 'postgres'
    }
  }
  spec: {
    selector: {
      app: 'postgres'
    }
    ports: [
      { port: 5432 }
    ]
  }
}

// ---------------------------------------------------------------------------
// Simulator: generates random step data on each /ticker call. Reaches the
// Radius-managed Postgres cross-namespace via its service FQDN.
// imagePullPolicy IfNotPresent so the kind-loaded local image is used.
// ---------------------------------------------------------------------------
resource simulator 'Applications.Core/containers@2023-10-01-preview' = {
  name: 'simulator'
  properties: {
    application: app.id
    container: {
      image: '${imageRegistry}/simulator:${imageTag}'
      imagePullPolicy: 'IfNotPresent'
      ports: {
        http: {
          containerPort: 8080
        }
      }
      env: {
        PG_DSN: {
          value: 'Host=postgres.default.svc.cluster.local;Port=5432;Username=postgres;Password=postgres;Database=stepup'
        }
      }
    }
    extensions: [
      { kind: 'daprSidecar', appId: 'simulator', appPort: 8080 }
    ]
  }
}

// ---------------------------------------------------------------------------
// Dapr cron binding: posts to the simulator's /ticker every 5s, so steps
// generate automatically. Must live in the simulator's namespace so its
// sidecar loads it. Validates the dapr.io/Component-via-Bicep pattern.
// ---------------------------------------------------------------------------
resource ticker 'dapr.io/Component@v1alpha1' = {
  metadata: {
    name: 'ticker'
    namespace: 'default-stepup'
  }
  spec: {
    type: 'bindings.cron'
    version: 'v1'
    metadata: [
      { name: 'schedule', value: '@every 5s' }
      { name: 'direction', value: 'input' }
    ]
  }
  scopes: [ 'simulator' ]
}

// ---------------------------------------------------------------------------
// Dapr pub/sub over the SHARED Redis (redis.default) — the same broker the
// Drasi PostDaprPubSub reaction publishes to, so the notifier sees those events.
// ---------------------------------------------------------------------------
resource pubsub 'dapr.io/Component@v1alpha1' = {
  metadata: {
    name: 'stepup-pubsub'
    namespace: 'default-stepup'
  }
  spec: {
    type: 'pubsub.redis'
    version: 'v1'
    metadata: [
      { name: 'redisHost', value: 'redis.default.svc.cluster.local:6379' }
      { name: 'redisPassword', value: '' }
    ]
  }
  scopes: [ 'notifier' ]
}

// ---------------------------------------------------------------------------
// Dapr HTTP output binding to the Discord webhook. URL read from the
// 'notifier-webhook' k8s secret (key 'url') via Dapr's built-in 'kubernetes'
// secret store — create that secret in default-stepup (see below).
// ---------------------------------------------------------------------------
resource discord 'dapr.io/Component@v1alpha1' = {
  metadata: {
    name: 'discord'
    namespace: 'default-stepup'
  }
  spec: {
    type: 'bindings.http'
    version: 'v1'
    metadata: [
      {
        name: 'url'
        secretKeyRef: {
          name: 'notifier-webhook'
          key: 'url'
        }
      }
    ]
  }
  auth: {
    secretStore: 'kubernetes'
  }
  scopes: [ 'notifier' ]
}

// ---------------------------------------------------------------------------
// Notifier: subscribes to stepup-pubsub/stepup-events and posts contest
// notifications to Discord. Event-driven only (no Postgres connection).
// ---------------------------------------------------------------------------
resource notifier 'Applications.Core/containers@2023-10-01-preview' = {
  name: 'notifier'
  properties: {
    application: app.id
    container: {
      image: '${imageRegistry}/notifier:${imageTag}'
      imagePullPolicy: 'IfNotPresent'
    }
    extensions: [
      {
        kind: 'daprSidecar'
        appId: 'notifier'
        appPort: 8080
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Clock: advances challenge_state.today on each /clock-cron call (accelerated
// mode by default, ~1 simulated day per tick). Writes to Postgres.
// ---------------------------------------------------------------------------
resource clock 'Applications.Core/containers@2023-10-01-preview' = {
  name: 'clock'
  properties: {
    application: app.id
    container: {
      image: '${imageRegistry}/clock:${imageTag}'
      imagePullPolicy: 'IfNotPresent'
      env: {
        PG_DSN: {
          value: 'Host=postgres.default.svc.cluster.local;Port=5432;Username=postgres;Password=postgres;Database=stepup'
        }
      }
    }
    extensions: [
      {
        kind: 'daprSidecar'
        appId: 'clock'
        appPort: 8080
      }
    ]
  }
}

// Dapr cron: posts to the clock's /clock-cron every 60s, advancing the day.
resource clockCron 'dapr.io/Component@v1alpha1' = {
  metadata: {
    name: 'clock-cron'
    namespace: 'default-stepup'
  }
  spec: {
    type: 'bindings.cron'
    version: 'v1'
    metadata: [
      { name: 'schedule', value: '@every 60s' }
      { name: 'direction', value: 'input' }
    ]
  }
  scopes: [ 'clock' ]
}

// ---------------------------------------------------------------------------
// Dashboard: static Vue app (nginx). No Dapr sidecar — it's a browser client
// that connects to the Drasi SignalR reaction hub via a relative `/hub` URL;
// nginx reverse-proxies /hub to dashboard-reaction-svc.drasi-system.svc.cluster.local:8080,
// so the browser reaches the hub through the dashboard (no `drasi tunnel` needed).
// ---------------------------------------------------------------------------
resource dashboard 'Applications.Core/containers@2023-10-01-preview' = {
  name: 'dashboard'
  properties: {
    application: app.id
    container: {
      image: '${imageRegistry}/dashboard:${imageTag}'
      imagePullPolicy: 'IfNotPresent'
      ports: {
        web: {
          containerPort: 80
        }
      }
    }
  }
}
