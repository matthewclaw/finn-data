-- ============================================================
-- Finn: personal finance structured memory
-- Migration 001 — core schema
-- ============================================================

-- Owners (Matthew, Kaylee, Shared, etc.)
CREATE TABLE IF NOT EXISTS owners (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL UNIQUE,
  email      TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Categories (Groceries, Transport, Eating Out, …)
CREATE TABLE IF NOT EXISTS categories (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL UNIQUE,
  parent_id  UUID REFERENCES categories(id) ON DELETE SET NULL,
  color      TEXT,
  icon       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Merchants with alias normalisation
-- aliases is a lowercase string array; GIN-indexed for contains queries
CREATE TABLE IF NOT EXISTS merchants (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  aliases     TEXT[] NOT NULL DEFAULT '{}',
  category_id UUID REFERENCES categories(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS merchants_aliases_gin ON merchants USING GIN (aliases);

-- Raw import audit trail — stored before any normalisation
CREATE TABLE IF NOT EXISTS import_batches (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source            TEXT NOT NULL,          -- 'manual', 'fnb_statement', 'csv', etc.
  owner_id          UUID REFERENCES owners(id) ON DELETE SET NULL,
  raw_payload       JSONB NOT NULL,
  imported_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  transaction_count INTEGER NOT NULL DEFAULT 0,
  notes             TEXT
);

-- Normalised transactions — source of truth
CREATE TABLE IF NOT EXISTS transactions (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id              UUID NOT NULL REFERENCES owners(id),
  date                  DATE NOT NULL,
  amount                NUMERIC(12, 2) NOT NULL,  -- positive = expense, negative = income/credit
  description           TEXT NOT NULL,
  merchant_id           UUID REFERENCES merchants(id) ON DELETE SET NULL,
  category_id           UUID REFERENCES categories(id) ON DELETE SET NULL,
  notes                 TEXT,
  tags                  TEXT[] NOT NULL DEFAULT '{}',
  import_batch_id       UUID REFERENCES import_batches(id) ON DELETE SET NULL,
  source                TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'import', 'recurring')),
  is_recurring          BOOLEAN NOT NULL DEFAULT FALSE,
  recurring_pattern_id  UUID,               -- FK added after recurring_patterns table
  dedup_hash            TEXT NOT NULL UNIQUE,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS transactions_owner_date    ON transactions (owner_id, date DESC);
CREATE INDEX IF NOT EXISTS transactions_owner_cat     ON transactions (owner_id, category_id);
CREATE INDEX IF NOT EXISTS transactions_merchant      ON transactions (merchant_id);
CREATE INDEX IF NOT EXISTS transactions_import_batch  ON transactions (import_batch_id);
CREATE INDEX IF NOT EXISTS transactions_tags_gin      ON transactions USING GIN (tags);

-- Detected recurring payment patterns
CREATE TABLE IF NOT EXISTS recurring_patterns (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id      UUID NOT NULL REFERENCES owners(id),
  merchant_id   UUID REFERENCES merchants(id) ON DELETE SET NULL,
  description   TEXT NOT NULL,
  amount        NUMERIC(12, 2) NOT NULL,
  frequency     TEXT NOT NULL CHECK (frequency IN ('monthly', 'weekly', 'annual', 'irregular')),
  day_of_month  INTEGER CHECK (day_of_month BETWEEN 1 AND 31),
  category_id   UUID REFERENCES categories(id) ON DELETE SET NULL,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  first_seen    DATE NOT NULL,
  last_seen     DATE NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (owner_id, description)
);

-- Back-fill FK from transactions to recurring_patterns
ALTER TABLE transactions
  ADD CONSTRAINT fk_recurring_pattern
  FOREIGN KEY (recurring_pattern_id) REFERENCES recurring_patterns(id) ON DELETE SET NULL;

-- Budgets (per owner + category + month)
CREATE TABLE IF NOT EXISTS budgets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id    UUID REFERENCES owners(id) ON DELETE CASCADE,  -- NULL = household budget
  category_id UUID NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  month       DATE NOT NULL,                                  -- always first of the month
  amount      NUMERIC(12, 2) NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (owner_id, category_id, month)
);

-- Auto-update updated_at on transactions
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER transactions_updated_at
  BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- Seed: default owners
-- ============================================================
INSERT INTO owners (name) VALUES ('matthew'), ('kaylee'), ('shared')
ON CONFLICT (name) DO NOTHING;

-- ============================================================
-- Seed: default categories
-- ============================================================
INSERT INTO categories (name) VALUES
  ('groceries'),
  ('eating out'),
  ('transport'),
  ('fuel'),
  ('subscriptions'),
  ('utilities'),
  ('medical'),
  ('clothing'),
  ('entertainment'),
  ('travel'),
  ('education'),
  ('home'),
  ('gifts'),
  ('income'),
  ('savings'),
  ('uncategorised')
ON CONFLICT (name) DO NOTHING;
