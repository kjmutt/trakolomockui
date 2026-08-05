-- ============================================================================
-- trakolo-master — the platform control-plane database (PostgreSQL 18+)
--
-- Requires 18 specifically for the native uuidv7() used on the append-only
-- audit tables (subscription_history, error_logs, staff_audit_log) — see
-- db/schema.sql's header for why. Everything else still uses
-- gen_random_uuid() (UUIDv4).
--
-- One database, owned by Trakolo, never by a tenant. It holds the tenant
-- registry (core.tenants) and every table behind the Platform Admin console
-- (platform.*: plans, pricing, subscriptions, leads, campaigns, error log,
-- email settings/templates, callback requests, staff audit log). It holds
-- no ticket, asset, backlog, or document data — that lives in each cloud
-- tenant's own dedicated database (see db/schema.sql), applied once per
-- tenant and routed to by core.tenants.db_host/db_name below.
--
-- Standalone/on-premise tenants are the exception: they run db/schema.sql on
-- their own Postgres, on their own network, with no subdomain and no
-- database connection Trakolo can reach. Their core.tenants row here exists
-- for licensing and reporting only — db_host/db_name/subdomain stay NULL by
-- the CHECK constraint below, and last_license_checkin_at is the only signal
-- Trakolo gets back from them (via periodic .trklic license validation, not
-- a live connection).
--
-- Apply with:  psql -d trakolo_master -f db/schema-master.sql
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;   -- case-insensitive email columns

-- Shared trigger: every table with updated_at gets touched automatically.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- SCHEMA: core — the tenant registry. This is the ONLY core table in
-- trakolo-master; everything else core.* (users, roles, teams, ...) lives
-- per-tenant, in the database this table points to.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS core;

CREATE TYPE core.deployment_model AS ENUM ('cloud', 'standalone');

-- 'shared'    — this tenant's requests are served by the shared app fleet,
--               its database sharing a Postgres cluster with other tenants.
-- 'dedicated' — instance-per-tenant: its own app containers and its own
--               Postgres cluster, which is the same artifact a standalone
--               customer installs, just hosted by us. See the tenancy-model
--               comparison in technical-design.html for when each applies.
CREATE TYPE core.compute_tier AS ENUM ('shared', 'dedicated');

CREATE TABLE core.tenants (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                     text NOT NULL,
  slug                     text NOT NULL UNIQUE,
  deployment_model         core.deployment_model NOT NULL DEFAULT 'cloud',

  -- Cloud only: how the app fleet finds and routes to this tenant's
  -- dedicated database. subdomain resolves to db_host/db_name on every
  -- request (see technical-design.html); wildcard DNS + TLS cover every
  -- subdomain, so adding a tenant never touches edge config.
  subdomain                text UNIQUE,              -- 'acme' -> acme.trakolo.com
  db_host                  text,                      -- e.g. 'tenant-db-12.postgres.trakolo.internal'
  db_name                  text,                      -- e.g. 'trakolo_acme'
  db_provisioned_at        timestamptz,
  compute_tier             core.compute_tier,         -- moving a tenant between tiers is this one value

  -- Standalone/on-premise only: no Trakolo-managed domain and no database
  -- Trakolo can connect to — the customer's own network owns both. These
  -- columns exist purely for license lifecycle, never for routing.
  install_contact_email    citext,
  last_license_checkin_at  timestamptz,

  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_tenants_routing CHECK (
    (deployment_model = 'cloud'      AND subdomain IS NOT NULL AND db_host IS NOT NULL AND db_name IS NOT NULL AND compute_tier IS NOT NULL)
    OR
    (deployment_model = 'standalone' AND subdomain IS NULL     AND db_host IS NULL     AND db_name IS NULL     AND compute_tier IS NULL)
  )
);
CREATE TRIGGER trg_tenants_updated BEFORE UPDATE ON core.tenants
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Framework-agnostic migration tracking — see db/schema.sql's copy of this
-- table for the full rationale; identical convention on both databases.
CREATE TABLE core.schema_migrations (
  version     text PRIMARY KEY,
  applied_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO core.schema_migrations (version) VALUES ('0001_initial');


-- ============================================================================
-- SCHEMA: platform — Trakolo-staff-only: editions, licensing, entitlements,
-- cross-tenant service health, SSP system email, and support intake.
-- Everything here is written by platform admins (saas-admin-*.html), never by
-- tenant users. Tables map directly to the platform console's pages: Home
-- (subscriptions + subscription_history), Pricing (features + plan_features),
-- Error log, Email settings / templates, and Callback requests.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS platform;

CREATE TYPE platform.staff_role AS ENUM ('owner', 'admin', 'support', 'billing', 'read_only');
CREATE TYPE platform.staff_status AS ENUM ('active', 'invited', 'suspended');

-- Trakolo's own staff directory — who can sign in to saas-admin-login.html
-- at all, and what they're allowed to do once they're in. Distinct from any
-- tenant's core.users; nobody in this table works for a customer.
CREATE TABLE platform.staff_users (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email          citext NOT NULL UNIQUE,
  name           text NOT NULL,
  role           platform.staff_role NOT NULL DEFAULT 'support',
  status         platform.staff_status NOT NULL DEFAULT 'invited',
  mfa_enrolled   boolean NOT NULL DEFAULT false,   -- hardware-key 2FA — the login page's stated requirement, enforced below
  invited_by_id  uuid REFERENCES platform.staff_users(id),
  last_login_at  timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_staff_active_requires_mfa CHECK (status <> 'active' OR mfa_enrolled)
);
CREATE INDEX idx_staff_users_role ON platform.staff_users(role);
CREATE INDEX idx_staff_users_invited_by_id ON platform.staff_users(invited_by_id);
CREATE TRIGGER trg_staff_users_updated BEFORE UPDATE ON platform.staff_users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE platform.plans (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL UNIQUE,     -- 'Free', 'Team', 'Business', 'Enterprise'
  price_monthly  numeric(10,2),
  price_yearly   numeric(10,2),
  seat_based     boolean NOT NULL DEFAULT true,
  sort_order     int NOT NULL DEFAULT 0,
  is_active      boolean NOT NULL DEFAULT true
);

-- Feature catalog behind the Pricing page's editable matrix — one row per
-- capability. Platform admins add rows here via "+ Add feature".
CREATE TABLE platform.features (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key          text NOT NULL UNIQUE,       -- 'rest_api', 'custom_domain', 'mfa', 'sso', ...
  category     text NOT NULL DEFAULT 'Essentials',
  label        text NOT NULL,
  value_type   text NOT NULL DEFAULT 'boolean' CHECK (value_type IN ('boolean', 'numeric')),
  sort_order   int NOT NULL DEFAULT 0,
  is_published boolean NOT NULL DEFAULT true,   -- shown on the public-facing pricing page
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- The matrix itself: which features each plan includes, and at what limit.
CREATE TABLE platform.plan_features (
  plan_id     uuid NOT NULL REFERENCES platform.plans(id) ON DELETE CASCADE,
  feature_id  uuid NOT NULL REFERENCES platform.features(id) ON DELETE CASCADE,
  enabled     boolean NOT NULL DEFAULT false,
  value       text,                        -- numeric limit or label, e.g. '5', 'Unlimited'; null for plain booleans
  PRIMARY KEY (plan_id, feature_id)
);
CREATE INDEX idx_plan_features_feature_id ON platform.plan_features(feature_id);

CREATE TYPE platform.subscription_status AS ENUM ('trialing', 'active', 'past_due', 'expired', 'canceled');
CREATE TYPE platform.contract_type AS ENUM ('monthly', 'yearly', 'perpetual');

CREATE TABLE platform.subscriptions (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  plan_id              uuid NOT NULL REFERENCES platform.plans(id),
  status               platform.subscription_status NOT NULL DEFAULT 'trialing',
  contract_type        platform.contract_type NOT NULL DEFAULT 'yearly',
  total_license_count  int NOT NULL DEFAULT 1,
  generated_date       date NOT NULL DEFAULT current_date,
  contract_from_date   date NOT NULL,
  contract_to_date     date NOT NULL,
  drop_dead_date       date NOT NULL,      -- hard cutoff past contract_to_date; access suspended after this
  license_key          text UNIQUE,
  generated_by_staff_id uuid REFERENCES platform.staff_users(id),  -- platform staff who generated it
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id)                       -- one active subscription per tenant
);
CREATE INDEX idx_subscriptions_plan_id ON platform.subscriptions(plan_id);
CREATE INDEX idx_subscriptions_generated_by_staff_id ON platform.subscriptions(generated_by_staff_id);
CREATE TRIGGER trg_subscriptions_updated BEFORE UPDATE ON platform.subscriptions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Every Renew / Upgrade / Downgrade from the Home page, so "why did this
-- tenant's contract change" always has an answer.
CREATE TYPE platform.subscription_action AS ENUM ('generated', 'renewed', 'upgraded', 'downgraded', 'cancelled');

CREATE TABLE platform.subscription_history (
  id                         uuid PRIMARY KEY DEFAULT uuidv7(),  -- time-ordered: append-only audit trail
  subscription_id            uuid NOT NULL REFERENCES platform.subscriptions(id) ON DELETE CASCADE,
  action                     platform.subscription_action NOT NULL,
  previous_plan_id           uuid REFERENCES platform.plans(id),
  new_plan_id                uuid REFERENCES platform.plans(id),
  previous_license_count     int,
  new_license_count          int,
  previous_contract_to_date  date,
  new_contract_to_date       date,
  cost                       numeric(12,2),
  performed_by_staff_id      uuid REFERENCES platform.staff_users(id),
  note                       text,
  created_at                 timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_subscription_history_previous_plan_id ON platform.subscription_history(previous_plan_id);
CREATE INDEX idx_subscription_history_new_plan_id ON platform.subscription_history(new_plan_id);
CREATE INDEX idx_subscription_history_performed_by_staff_id ON platform.subscription_history(performed_by_staff_id);
CREATE INDEX idx_subscription_history_subscription ON platform.subscription_history(subscription_id, created_at DESC);

-- Per-tenant, per-feature overrides on top of the plan (e.g. a trial add-on).
CREATE TABLE platform.tenant_entitlements (
  tenant_id    uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  feature_key  text NOT NULL,
  enabled      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, feature_key)
);

CREATE TYPE platform.service_status AS ENUM ('operational', 'degraded', 'outage');

-- Cross-tenant infra health — what Admin > System status reads from.
CREATE TABLE platform.services (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL UNIQUE,     -- 'API service', 'Database', 'AI agent worker', ...
  status         platform.service_status NOT NULL DEFAULT 'operational',
  last_checked_at timestamptz NOT NULL DEFAULT now()
);

-- Home > Error log: platform + per-tenant API/background-job failures.
CREATE TYPE platform.log_type AS ENUM ('info', 'warning', 'error');

CREATE TABLE platform.error_logs (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),  -- time-ordered: append-only, ever-growing
  tenant_id     uuid REFERENCES core.tenants(id) ON DELETE CASCADE,   -- null = platform-wide
  service_name  text NOT NULL,
  api_method    text,
  api_url       text,
  log_type      platform.log_type NOT NULL DEFAULT 'error',
  message       text NOT NULL,
  logged_on     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_error_logs_tenant_time ON platform.error_logs(tenant_id, logged_on DESC);

-- Outbound mail accounts used for SSP system email (signup, password reset —
-- not the tenant's own ticket-ingestion mailboxes, see core.integrations).
CREATE TABLE platform.ssp_email_settings (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                     text NOT NULL,
  provider                 text NOT NULL DEFAULT 'smtp' CHECK (provider IN ('smtp', 'outlook', 'gmail')),
  from_address             citext NOT NULL,
  client_id                text,
  client_secret_encrypted  bytea,       -- envelope-encrypted (e.g. pgcrypto pgp_sym_encrypt with a KMS-held key), never plaintext.
                                        -- NOT a hash: this has to be decrypted to authenticate outbound to the mail provider,
                                        -- unlike a password, so a one-way hash can't work here.
  smtp_host                text,
  smtp_port                int,
  is_active                boolean NOT NULL DEFAULT true,
  created_at               timestamptz NOT NULL DEFAULT now()
);

-- System email templates the SSP sends on account-lifecycle events.
CREATE TABLE platform.ssp_email_templates (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code           text NOT NULL UNIQUE,   -- 'signup', 'account_created', 'forgot_password', 'reset_password'
  name           text NOT NULL,
  subject        text NOT NULL,
  body_html      text NOT NULL,
  dynamic_fields text[] NOT NULL DEFAULT '{}',
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_ssp_email_templates_updated BEFORE UPDATE ON platform.ssp_email_templates
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- "Request a callback" leads from the pricing/marketing site and SSP login.
CREATE TYPE platform.callback_status AS ENUM ('new', 'contacted', 'closed');

CREATE TABLE platform.callback_requests (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid REFERENCES core.tenants(id),
  name           text NOT NULL,
  mobile_number  text,
  email          citext,
  available_at   timestamptz,
  status         platform.callback_status NOT NULL DEFAULT 'new',
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_callback_requests_tenant_id ON platform.callback_requests(tenant_id);

-- Every privileged action a Trakolo staff member takes in the platform
-- console — separate from core.audit_log, which is per-tenant.
CREATE TABLE platform.staff_audit_log (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),  -- time-ordered: append-only, ever-growing
  staff_id    uuid NOT NULL REFERENCES platform.staff_users(id),
  action      text NOT NULL,        -- 'subscription.renewed', 'plan_feature.toggled', ...
  target_type text NOT NULL,
  target_id   uuid,
  metadata    jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_staff_audit_log_staff_id ON platform.staff_audit_log(staff_id);
CREATE INDEX idx_staff_audit_log_time ON platform.staff_audit_log(created_at DESC);

-- Inbound sales enquiries — phone calls logged by staff, web/referral leads —
-- ahead of becoming a core.tenants row. See Platform Admin > Leads.
CREATE TYPE platform.lead_source AS ENUM ('phone', 'web', 'referral', 'email', 'walk_in', 'other');
CREATE TYPE platform.lead_status AS ENUM ('new', 'contacted', 'qualified', 'converted', 'lost');

CREATE TABLE platform.leads (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_name        text NOT NULL,
  organisation_name   text NOT NULL,
  organisation_notes  text,                    -- industry, size, anything freeform from the call
  email               citext,
  phone               text,
  users_interested    int,
  modules_interested  text[] NOT NULL DEFAULT '{}',   -- 'IT', 'SAM', 'Dev', 'Ops', 'Docs'
  source              platform.lead_source NOT NULL DEFAULT 'other',
  status              platform.lead_status NOT NULL DEFAULT 'new',
  notes               text,
  converted_tenant_id uuid REFERENCES core.tenants(id),   -- set once they sign
  logged_by_staff_id  uuid REFERENCES platform.staff_users(id),
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_leads_converted_tenant_id ON platform.leads(converted_tenant_id);
CREATE INDEX idx_leads_logged_by_staff_id ON platform.leads(logged_by_staff_id);
CREATE INDEX idx_leads_status ON platform.leads(status);

-- Who Trakolo staff actually call at each account — sales/success-facing,
-- distinct from core.contacts (the tenant's own SSP requesters).
CREATE TABLE platform.account_contacts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  title       text,
  email       citext,
  phone       text,
  is_primary  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_account_contacts_tenant ON platform.account_contacts(tenant_id);

-- Promotional email blasts to the customer base — separate from
-- ssp_email_templates, which is transactional account-lifecycle mail.
CREATE TYPE platform.campaign_segment AS ENUM ('all', 'by_plan', 'by_status', 'custom');
CREATE TYPE platform.campaign_status AS ENUM ('draft', 'sent');

CREATE TABLE platform.campaigns (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject         text NOT NULL,
  body_html       text NOT NULL,
  segment         platform.campaign_segment NOT NULL DEFAULT 'all',
  segment_plan_id uuid REFERENCES platform.plans(id),   -- set when segment = 'by_plan'
  status          platform.campaign_status NOT NULL DEFAULT 'draft',
  sent_by_staff_id uuid REFERENCES platform.staff_users(id),
  sent_at         timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_campaigns_segment_plan_id ON platform.campaigns(segment_plan_id);
CREATE INDEX idx_campaigns_sent_by_staff_id ON platform.campaigns(sent_by_staff_id);

CREATE TABLE platform.campaign_recipients (
  campaign_id  uuid NOT NULL REFERENCES platform.campaigns(id) ON DELETE CASCADE,
  tenant_id    uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  opened_at    timestamptz,
  PRIMARY KEY (campaign_id, tenant_id)
);
CREATE INDEX idx_campaign_recipients_tenant_id ON platform.campaign_recipients(tenant_id);


-- ============================================================================


-- ============================================================================
-- Seed: Trakolo's own staff roster — who can sign in to this console. Names
-- and emails match what saas-admin-console.html already shows under
-- "Generated by" for each tenant (t.reyes@trakolo.com, m.osei@trakolo.com,
-- platform-ops@trakolo.com).
-- ============================================================================
INSERT INTO platform.staff_users (email, name, role, status, mfa_enrolled, last_login_at) VALUES
  ('sofia.lindqvist@trakolo.com', 'Sofia Lindqvist', 'owner', 'active', true, now() - interval '2 hours');

INSERT INTO platform.staff_users (email, name, role, status, mfa_enrolled, invited_by_id, last_login_at)
SELECT 'theo.reyes@trakolo.com', 'Theo Reyes', 'admin', 'active', true, id, now() - interval '1 day'
FROM platform.staff_users WHERE email = 'sofia.lindqvist@trakolo.com';

INSERT INTO platform.staff_users (email, name, role, status, mfa_enrolled, invited_by_id, last_login_at)
SELECT 'maya.osei@trakolo.com', 'Maya Osei', 'admin', 'active', true, id, now() - interval '3 hours'
FROM platform.staff_users WHERE email = 'sofia.lindqvist@trakolo.com';

-- The shared ops inbox already shown as this workspace's own subscription
-- generator in saas-admin-console.html — a service account, not a person,
-- kept in the same directory so staff_audit_log/subscriptions can still
-- point at exactly one row regardless of who's on rotation.
INSERT INTO platform.staff_users (email, name, role, status, mfa_enrolled, invited_by_id, last_login_at)
SELECT 'platform-ops@trakolo.com', 'Platform Ops', 'admin', 'active', true, id, now() - interval '6 hours'
FROM platform.staff_users WHERE email = 'sofia.lindqvist@trakolo.com';

INSERT INTO platform.staff_users (email, name, role, status, mfa_enrolled, invited_by_id, last_login_at)
SELECT 'devon.marsh@trakolo.com', 'Devon Marsh', 'support', 'active', true, id, now() - interval '5 days'
FROM platform.staff_users WHERE email = 'theo.reyes@trakolo.com';

INSERT INTO platform.staff_users (email, name, role, status, mfa_enrolled, invited_by_id, last_login_at)
SELECT 'priya.chandran@trakolo.com', 'Priya Chandran', 'billing', 'active', true, id, now() - interval '1 day'
FROM platform.staff_users WHERE email = 'sofia.lindqvist@trakolo.com';

-- Invited, not yet through 2FA setup — chk_staff_active_requires_mfa is why
-- status can't just be flipped to 'active' before mfa_enrolled is true.
INSERT INTO platform.staff_users (email, name, role, status, mfa_enrolled, invited_by_id)
SELECT 'jonas.weber@trakolo.com', 'Jonas Weber', 'support', 'invited', false, id
FROM platform.staff_users WHERE email = 'theo.reyes@trakolo.com';

-- Offboarded — access revoked, row kept so past audit history and generated
-- licenses still resolve to someone instead of a dangling reference.
INSERT INTO platform.staff_users (email, name, role, status, mfa_enrolled, invited_by_id, last_login_at)
SELECT 'owen.blake@trakolo.com', 'Owen Blake', 'read_only', 'suspended', true, id, now() - interval '95 days'
FROM platform.staff_users WHERE email = 'sofia.lindqvist@trakolo.com';


-- ============================================================================
-- Seed: the plan catalog, plus the two tenants already in the mockup — Acme
-- Corp (an ordinary cloud customer) and Trakolo itself (customer #1,
-- dogfooding its own product on its own dedicated tenant database — see
-- saas-admin-console.html).
-- ============================================================================
INSERT INTO platform.plans (name, price_monthly, price_yearly, seat_based, sort_order) VALUES
  ('Free',       0,     0,      true, 0),
  ('Team',       6.30,  63.00,  true, 1),
  ('Business',   14.00, 140.00, true, 2),
  ('Enterprise', NULL,  NULL,   true, 3);   -- custom pricing, quoted per deal

-- Acme is an ordinary Team-plan tenant on the shared fleet; Trakolo's own
-- workspace is Enterprise and runs instance-per-tenant, which also keeps us
-- honest about the dedicated path by dogfooding it.
INSERT INTO core.tenants (id, name, slug, deployment_model, subdomain, db_host, db_name, db_provisioned_at, compute_tier) VALUES
  ('a1111111-1111-4111-8111-111111111111', 'Acme Corp', 'acme',    'cloud', 'acme',    'tenant-db-01.postgres.trakolo.internal', 'trakolo_acme',    now(),        'shared'),
  ('a2222222-2222-4222-8222-222222222222', 'Trakolo',   'trakolo', 'cloud', 'support', 'tenant-db-00.postgres.trakolo.internal', 'trakolo_support', '2025-01-01', 'dedicated');

INSERT INTO platform.subscriptions (tenant_id, plan_id, status, contract_type, total_license_count, generated_date, contract_from_date, contract_to_date, drop_dead_date, license_key, generated_by_staff_id)
SELECT t.id, p.id, 'active', 'monthly', 84, current_date, '2026-03-01', '2027-03-01', '2027-03-15', NULL,
  (SELECT id FROM platform.staff_users WHERE email = 'theo.reyes@trakolo.com')
FROM core.tenants t, platform.plans p WHERE t.slug = 'acme' AND p.name = 'Team';

-- Perpetual/internal: contract_to_date and drop_dead_date use the same
-- far-future sentinel the console already renders as "—" for Perpetual rows.
INSERT INTO platform.subscriptions (tenant_id, plan_id, status, contract_type, total_license_count, generated_date, contract_from_date, contract_to_date, drop_dead_date, license_key, generated_by_staff_id)
SELECT t.id, p.id, 'active', 'perpetual', 46, '2025-01-01', '2025-01-01', '2099-01-01', '2099-01-01', 'TRK-TRAKOLO-2025-INTERNAL',
  (SELECT id FROM platform.staff_users WHERE email = 'platform-ops@trakolo.com')
FROM core.tenants t, platform.plans p WHERE t.slug = 'trakolo' AND p.name = 'Enterprise';


-- ============================================================================
-- Least-privilege application role — see db/schema.sql's copy of this
-- section for the full rationale (NOLOGIN bundle, per-environment LOGIN
-- role granted it out-of-band, no DDL rights at all). Only the Platform
-- Admin backend ever connects to this database as trakolo_master_role;
-- no tenant, and no per-tenant application code, ever does.
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'trakolo_master_role') THEN
    CREATE ROLE trakolo_master_role NOLOGIN;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA core, platform TO trakolo_master_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, platform TO trakolo_master_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, platform
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO trakolo_master_role;
