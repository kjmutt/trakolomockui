-- ============================================================================
-- Trakolo — per-tenant database schema (PostgreSQL 18+)
--
-- Requires 18 specifically for the native uuidv7() used on high-insert
-- tables (tickets, ticket_activity, ticket_attachments, notifications,
-- audit_log) — time-ordered ids avoid the B-tree bloat random UUIDv4 causes
-- on tables that only ever grow. Every other table still uses
-- gen_random_uuid() (UUIDv4): fine for low-insert-rate reference data, and
-- there's no reason to pay the (tiny) extra complexity where it doesn't
-- matter. install/docker-compose.yml already pins postgres:18-alpine.
--
-- Database-per-tenant model: every cloud tenant gets its own dedicated
-- Postgres database running exactly this file, and an on-premise/standalone
-- install is the same thing on the customer's own server — one tenant, one
-- database, no shared infrastructure to reason about. Because the database
-- itself is the tenant boundary, nothing in here carries a tenant_id column;
-- the old shared-cluster / row-level-scoping design lived in a single
-- database and is retired in favor of this one.
--
-- Trakolo's own control plane — the tenant registry (which db each tenant's
-- data lives in, cloud vs. standalone, subdomain routing), plans, pricing,
-- subscriptions, leads, campaigns — lives in a separate database and file:
-- see db/schema-master.sql ("trakolo-master"). Nothing in this file
-- references that database; Postgres has no cross-database foreign keys,
-- so the two are linked only by tenant_id, stored here in core.workspace and
-- resolved to a db_host/db_name by trakolo-master at connection time.
--
-- Apply with:  psql -d <tenant db, e.g. trakolo_acme> -f db/schema.sql
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
-- SCHEMA: core — tenancy, identity, access control, cross-module utilities
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS core;

-- This database belongs to exactly one tenant — that's the whole point of the
-- database-per-tenant model (see trakolo-master's core.tenants for the
-- registry every one of these is provisioned from). workspace is a single-row
-- table so the app running against this DB can identify itself without a
-- cross-database lookup; enforced by the fixed id default plus the check.
CREATE TABLE core.workspace (
  id           uuid PRIMARY KEY DEFAULT '00000000-0000-0000-0000-000000000001',
  tenant_id    uuid NOT NULL,        -- mirrors this workspace's row id in trakolo-master core.tenants
  name         text NOT NULL,
  slug         text NOT NULL,
  deployment_model text NOT NULL DEFAULT 'cloud' CHECK (deployment_model IN ('cloud', 'standalone')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (id = '00000000-0000-0000-0000-000000000001')
);
CREATE TRIGGER trg_workspace_updated BEFORE UPDATE ON core.workspace
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TYPE core.user_status AS ENUM ('active', 'invited', 'suspended');

CREATE TABLE core.users (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email            citext NOT NULL,
  name             text NOT NULL,
  avatar_initials  text,
  status           core.user_status NOT NULL DEFAULT 'invited',
  last_login_at    timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (email)
);
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON core.users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Contacts are SSP/end-user requesters (Section: Contacts directory) — a
-- distinct population from core.users, who are internal agents/admins.
CREATE TABLE core.contacts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  email       citext NOT NULL,
  department  text,
  title       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (email)
);

CREATE TABLE core.roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,               -- Admin, Manager, Agent, Viewer, or a custom role
  is_system   boolean NOT NULL DEFAULT false,
  UNIQUE (name)
);

CREATE TABLE core.permissions (
  id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key    text NOT NULL UNIQUE,             -- e.g. 'itsm.tickets.write', 'sam.assets.delete'
  label  text NOT NULL
);

CREATE TABLE core.role_permissions (
  role_id       uuid NOT NULL REFERENCES core.roles(id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES core.permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);
CREATE INDEX idx_role_permissions_permission_id ON core.role_permissions(permission_id);

CREATE TABLE core.user_roles (
  user_id  uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  role_id  uuid NOT NULL REFERENCES core.roles(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);
CREATE INDEX idx_user_roles_role_id ON core.user_roles(role_id);

-- Support groups (e.g. "IT Ops", "Infrastructure", "Security")
CREATE TABLE core.teams (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  UNIQUE (name)
);
CREATE TABLE core.team_members (
  team_id  uuid NOT NULL REFERENCES core.teams(id) ON DELETE CASCADE,
  user_id  uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  PRIMARY KEY (team_id, user_id)
);
CREATE INDEX idx_team_members_user_id ON core.team_members(user_id);

-- Approval groups (used by change requests, access requests, catalog items)
CREATE TABLE core.approval_groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  UNIQUE (name)
);
CREATE TABLE core.approval_group_members (
  approval_group_id  uuid NOT NULL REFERENCES core.approval_groups(id) ON DELETE CASCADE,
  user_id            uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  PRIMARY KEY (approval_group_id, user_id)
);
CREATE INDEX idx_approval_group_members_user_id ON core.approval_group_members(user_id);

CREATE TABLE core.notifications (
  id          uuid PRIMARY KEY DEFAULT uuidv7(),        -- time-ordered: this table is high-insert, never random-accessed by id
  user_id     uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  type        text NOT NULL,               -- 'sla_breach', 'approval_pending', 'oncall_assigned', ...
  title       text NOT NULL,
  body        text,
  link_url    text,
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_notifications_user_unread ON core.notifications(user_id) WHERE read_at IS NULL;

CREATE TABLE core.api_keys (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  key_hash    text NOT NULL,               -- never store the raw key
  scopes      text[] NOT NULL DEFAULT '{}',
  created_by  uuid REFERENCES core.users(id),
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_api_keys_created_by ON core.api_keys(created_by);

CREATE TABLE core.integrations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider         text NOT NULL,          -- 'slack', 'github', 'okta', 'jira', ...
  status           text NOT NULL DEFAULT 'not_connected',
  config           jsonb NOT NULL DEFAULT '{}',
  last_synced_at   timestamptz,
  UNIQUE (provider)
);

CREATE TABLE core.feature_flags (
  feature_key text NOT NULL,               -- 'knowledge_base', 'ai_copilot', 'change_management', ...
  enabled     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (feature_key)
);

-- Every admin action and privileged change — see Admin > Audit log.
CREATE TABLE core.audit_log (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),        -- time-ordered: append-only, ever-growing, never random-accessed by id
  actor_user_id uuid REFERENCES core.users(id),
  action       text NOT NULL,              -- 'role.updated', 'business_rule.created', ...
  target_type  text NOT NULL,
  target_id    uuid,
  metadata     jsonb NOT NULL DEFAULT '{}',
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_log_actor_user_id ON core.audit_log(actor_user_id);
CREATE INDEX idx_audit_log_time ON core.audit_log(created_at DESC);

-- Framework-agnostic migration tracking. This file is "0001_initial";
-- future schema changes ship as numbered files (0002_*.sql, ...) that check
-- for their own version here before applying and INSERT it after — so
-- re-running a migration runner against an already-migrated tenant database
-- is a no-op instead of an "already exists" error. Which tool wraps this
-- convention (Flyway, sqlx, node-pg-migrate, a hand-rolled script) is an
-- app-stack decision; this table only needs to exist, not be owned by one.
CREATE TABLE core.schema_migrations (
  version     text PRIMARY KEY,
  applied_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO core.schema_migrations (version) VALUES ('0001_initial');


-- ============================================================================
-- SCHEMA: itsm — service desk, problems, change management, catalog, on-call
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS itsm;

CREATE TYPE itsm.priority AS ENUM ('low', 'normal', 'high', 'urgent');
CREATE TYPE itsm.ticket_source AS ENUM ('portal', 'email', 'phone', 'chat', 'slack', 'api');
CREATE TYPE itsm.ticket_status AS ENUM (
  'open', 'in_progress', 'awaiting_customer', 'escalated', 'resolved', 'closed', 'merged'
);

-- Tree-structured, unlimited depth (e.g. Hardware > Laptops > Battery), same
-- self-referencing pattern as docs.folders.
CREATE TABLE itsm.ticket_categories (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_category_id  uuid REFERENCES itsm.ticket_categories(id),
  name                text NOT NULL,
  sort_order          int NOT NULL DEFAULT 0
);
CREATE INDEX idx_ticket_categories_parent ON itsm.ticket_categories(parent_category_id);

CREATE TABLE itsm.tickets (
  id                 uuid PRIMARY KEY DEFAULT uuidv7(),  -- time-ordered: this is the highest-insert-rate table in the schema
  ticket_number      text NOT NULL,        -- display id, e.g. 'TS-4833'
  subject            text NOT NULL,
  category_id        uuid REFERENCES itsm.ticket_categories(id),
  priority           itsm.priority NOT NULL DEFAULT 'normal',
  source             itsm.ticket_source NOT NULL DEFAULT 'portal',
  status             itsm.ticket_status NOT NULL DEFAULT 'open',
  requester_contact_id uuid REFERENCES core.contacts(id),
  assignee_user_id   uuid REFERENCES core.users(id),
  escalation_level   smallint NOT NULL DEFAULT 0,
  sla_due_at         timestamptz,
  sla_breached_at    timestamptz,
  resolved_at        timestamptz,
  merged_into_id     uuid REFERENCES itsm.tickets(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (ticket_number)
);
CREATE INDEX idx_tickets_merged_into_id ON itsm.tickets(merged_into_id);
CREATE INDEX idx_tickets_requester_contact_id ON itsm.tickets(requester_contact_id);
CREATE INDEX idx_tickets_status ON itsm.tickets(status);
CREATE INDEX idx_tickets_assignee ON itsm.tickets(assignee_user_id);
CREATE INDEX idx_tickets_category ON itsm.tickets(category_id);
CREATE INDEX idx_tickets_sla_due ON itsm.tickets(sla_due_at) WHERE status NOT IN ('resolved', 'closed', 'merged');
CREATE TRIGGER trg_tickets_updated BEFORE UPDATE ON itsm.tickets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TYPE itsm.actor_type AS ENUM ('user', 'contact', 'ai_agent', 'system');

CREATE TABLE itsm.ticket_activity (
  id           uuid PRIMARY KEY DEFAULT uuidv7(),        -- time-ordered: every comment/status change on every ticket lands here
  ticket_id    uuid NOT NULL REFERENCES itsm.tickets(id) ON DELETE CASCADE,
  actor_type   itsm.actor_type NOT NULL,
  actor_user_id uuid REFERENCES core.users(id),
  actor_label  text,                       -- fallback display name (e.g. 'Trakolo AI agent')
  body         text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ticket_activity_actor_user_id ON itsm.ticket_activity(actor_user_id);
CREATE INDEX idx_ticket_activity_ticket ON itsm.ticket_activity(ticket_id, created_at);

CREATE TABLE itsm.ticket_attachments (
  id            uuid PRIMARY KEY DEFAULT uuidv7(),       -- time-ordered: append-only alongside ticket_activity
  ticket_id     uuid NOT NULL REFERENCES itsm.tickets(id) ON DELETE CASCADE,
  filename      text NOT NULL,
  content_type  text,
  size_bytes    bigint,
  storage_url   text NOT NULL,
  uploaded_by   uuid REFERENCES core.users(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ticket_attachments_uploaded_by ON itsm.ticket_attachments(uploaded_by);
CREATE INDEX idx_ticket_attachments_ticket ON itsm.ticket_attachments(ticket_id);

-- Generic cross-module links (ticket <-> ticket, ticket <-> dev card, ticket
-- <-> change request). linked_type + linked_id is a loose polymorphic
-- reference by design — the alternative (one FK column per linkable type)
-- doesn't scale as new modules link into tickets.
CREATE TABLE itsm.ticket_links (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id    uuid NOT NULL REFERENCES itsm.tickets(id) ON DELETE CASCADE,
  linked_type  text NOT NULL,              -- 'ticket' | 'backlog_item' | 'change_request' | 'problem'
  linked_id    uuid NOT NULL,
  label        text,                       -- display text, e.g. 'DEV-1058 · Sprint 34'
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (ticket_id, linked_type, linked_id)
);

CREATE TYPE itsm.problem_status AS ENUM ('open', 'workaround_posted', 'monitoring', 'closed');

CREATE TABLE itsm.problems (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  problem_number text NOT NULL,            -- 'PRB-0007'
  title          text NOT NULL,
  status         itsm.problem_status NOT NULL DEFAULT 'open',
  root_cause     text,
  workaround     text,
  owner_user_id  uuid REFERENCES core.users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  closed_at      timestamptz,
  UNIQUE (problem_number)
);
CREATE INDEX idx_problems_owner_user_id ON itsm.problems(owner_user_id);
CREATE TABLE itsm.problem_incidents (
  problem_id  uuid NOT NULL REFERENCES itsm.problems(id) ON DELETE CASCADE,
  ticket_id   uuid NOT NULL REFERENCES itsm.tickets(id) ON DELETE CASCADE,
  PRIMARY KEY (problem_id, ticket_id)
);
CREATE INDEX idx_problem_incidents_ticket_id ON itsm.problem_incidents(ticket_id);

CREATE TYPE itsm.change_status AS ENUM ('draft', 'pending_approval', 'approved', 'rejected', 'deployed', 'rolled_back');
CREATE TYPE itsm.change_risk AS ENUM ('low', 'medium', 'high');

CREATE TABLE itsm.change_requests (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cr_number              text NOT NULL,    -- 'CR-0091'
  title                  text NOT NULL,
  description            text,
  risk                   itsm.change_risk NOT NULL DEFAULT 'low',
  status                 itsm.change_status NOT NULL DEFAULT 'draft',
  requested_by_user_id   uuid REFERENCES core.users(id),
  source_ticket_id       uuid REFERENCES itsm.tickets(id),   -- the use-case ticket, if any
  backlog_item_id        uuid,             -- FK added after dev.backlog_items exists (see below)
  deployment_window_start timestamptz,
  deployment_window_end   timestamptz,
  deployed_at            timestamptz,
  rollback_plan          text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cr_number)
);
CREATE TRIGGER trg_change_requests_updated BEFORE UPDATE ON itsm.change_requests
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX idx_change_requests_source_ticket_id ON itsm.change_requests(source_ticket_id);
CREATE INDEX idx_change_requests_requested_by_user_id ON itsm.change_requests(requested_by_user_id);
CREATE INDEX idx_change_requests_backlog_item_id ON itsm.change_requests(backlog_item_id);
CREATE INDEX idx_change_requests_status ON itsm.change_requests(status);

CREATE TYPE itsm.approval_decision AS ENUM ('pending', 'approved', 'rejected');

CREATE TABLE itsm.change_approvals (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  change_request_id  uuid NOT NULL REFERENCES itsm.change_requests(id) ON DELETE CASCADE,
  approval_group_id  uuid REFERENCES core.approval_groups(id),
  approver_user_id   uuid REFERENCES core.users(id),
  decision           itsm.approval_decision NOT NULL DEFAULT 'pending',
  comment            text,
  decided_at         timestamptz
);
CREATE INDEX idx_change_approvals_approval_group_id ON itsm.change_approvals(approval_group_id);
CREATE INDEX idx_change_approvals_change_request_id ON itsm.change_approvals(change_request_id);
CREATE INDEX idx_change_approvals_approver_user_id ON itsm.change_approvals(approver_user_id);

CREATE TABLE itsm.sla_policies (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  priority          itsm.priority NOT NULL,
  response_minutes  int NOT NULL,
  resolution_minutes int NOT NULL,
  UNIQUE (priority)
);

CREATE TABLE itsm.business_rules (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  trigger     text NOT NULL,               -- 'ticket.created', 'ticket.escalated', ...
  conditions  jsonb NOT NULL DEFAULT '[]',
  actions     jsonb NOT NULL DEFAULT '[]',
  run_order   int NOT NULL DEFAULT 0,
  enabled     boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_business_rules_order ON itsm.business_rules(run_order);

CREATE TABLE itsm.service_catalog_categories (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_category_id  uuid REFERENCES itsm.service_catalog_categories(id),
  name                text NOT NULL,
  sort_order          int NOT NULL DEFAULT 0
);
CREATE INDEX idx_service_catalog_categories_parent ON itsm.service_catalog_categories(parent_category_id);

CREATE TABLE itsm.service_catalog_items (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                    text NOT NULL,
  description             text,
  category_id             uuid REFERENCES itsm.service_catalog_categories(id),
  approval_required       boolean NOT NULL DEFAULT false,
  fulfillment_sla_minutes int,
  automated               boolean NOT NULL DEFAULT false
);
CREATE INDEX idx_service_catalog_items_category ON itsm.service_catalog_items(category_id);

CREATE TABLE itsm.catalog_requests (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  catalog_item_id     uuid NOT NULL REFERENCES itsm.service_catalog_items(id),
  requested_by_contact_id uuid REFERENCES core.contacts(id),
  ticket_id           uuid REFERENCES itsm.tickets(id),
  status              itsm.ticket_status NOT NULL DEFAULT 'open',
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_catalog_requests_requested_by_contact_id ON itsm.catalog_requests(requested_by_contact_id);
CREATE INDEX idx_catalog_requests_ticket_id ON itsm.catalog_requests(ticket_id);
CREATE INDEX idx_catalog_requests_catalog_item_id ON itsm.catalog_requests(catalog_item_id);

CREATE TABLE itsm.kb_categories (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_category_id  uuid REFERENCES itsm.kb_categories(id),
  name                text NOT NULL,
  sort_order          int NOT NULL DEFAULT 0
);
CREATE INDEX idx_kb_categories_parent ON itsm.kb_categories(parent_category_id);

CREATE TABLE itsm.kb_articles (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  article_number    text,                 -- 'KB-0041'
  title             text NOT NULL,
  body              text NOT NULL,
  category_id       uuid REFERENCES itsm.kb_categories(id),
  view_count        int NOT NULL DEFAULT 0,
  deflection_count  int NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_kb_articles_category ON itsm.kb_articles(category_id);
CREATE TRIGGER trg_kb_articles_updated BEFORE UPDATE ON itsm.kb_articles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE itsm.oncall_schedules (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL,
  escalation_policy  jsonb NOT NULL DEFAULT '{}'  -- L1 -> L2 -> L3 timing/paging rules
);
CREATE TABLE itsm.oncall_rotations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  schedule_id  uuid NOT NULL REFERENCES itsm.oncall_schedules(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES core.users(id),
  starts_at    timestamptz NOT NULL,
  ends_at      timestamptz NOT NULL
);
CREATE INDEX idx_oncall_rotations_user_id ON itsm.oncall_rotations(user_id);
CREATE INDEX idx_oncall_rotations_window ON itsm.oncall_rotations(schedule_id, starts_at, ends_at);


-- ============================================================================
-- SCHEMA: sam — software & hardware asset management
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS sam;

CREATE TYPE sam.asset_type AS ENUM ('hardware', 'software', 'license', 'mobile');
CREATE TYPE sam.asset_status AS ENUM ('active', 'in_repair', 'idle', 'retired');

CREATE TABLE sam.assets (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_tag      text NOT NULL,            -- 'HW-00417', 'SW-01188'
  name           text NOT NULL,
  type           sam.asset_type NOT NULL,
  status         sam.asset_status NOT NULL DEFAULT 'active',
  owner_user_id  uuid REFERENCES core.users(id),
  location       text,
  seats_total    int,                      -- for license-type assets
  seats_used     int,
  cost_annual    numeric(12,2),
  purchased_at   date,
  renews_at      date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (asset_tag)
);
CREATE INDEX idx_assets_owner_user_id ON sam.assets(owner_user_id);
CREATE INDEX idx_assets_type ON sam.assets(type);
CREATE INDEX idx_assets_renews_at ON sam.assets(renews_at) WHERE status = 'active';
CREATE TRIGGER trg_assets_updated BEFORE UPDATE ON sam.assets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE sam.asset_assignments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id        uuid NOT NULL REFERENCES sam.assets(id) ON DELETE CASCADE,
  assigned_to_user_id uuid NOT NULL REFERENCES core.users(id),
  assigned_at     timestamptz NOT NULL DEFAULT now(),
  unassigned_at   timestamptz
);
CREATE INDEX idx_asset_assignments_assigned_to_user_id ON sam.asset_assignments(assigned_to_user_id);
CREATE INDEX idx_asset_assignments_asset ON sam.asset_assignments(asset_id);

CREATE TYPE sam.renewal_status AS ENUM ('upcoming', 'renewed', 'reclaimed', 'lapsed');

CREATE TABLE sam.license_renewals (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id      uuid NOT NULL REFERENCES sam.assets(id) ON DELETE CASCADE,
  renews_at     date NOT NULL,
  value         numeric(12,2),
  status        sam.renewal_status NOT NULL DEFAULT 'upcoming',
  reminder_sent_at timestamptz
);
CREATE INDEX idx_license_renewals_asset_id ON sam.license_renewals(asset_id);
CREATE INDEX idx_license_renewals_due ON sam.license_renewals(renews_at) WHERE status = 'upcoming';

CREATE TYPE sam.scan_type AS ENUM ('agent', 'network');
CREATE TYPE sam.scan_status AS ENUM ('running', 'completed', 'failed');

CREATE TABLE sam.discovery_scans (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scan_type        sam.scan_type NOT NULL,
  status           sam.scan_status NOT NULL DEFAULT 'running',
  assets_found     int NOT NULL DEFAULT 0,
  unmanaged_found  int NOT NULL DEFAULT 0,
  started_at       timestamptz NOT NULL DEFAULT now(),
  completed_at     timestamptz
);


-- ============================================================================
-- SCHEMA: dev — projects, scrum teams, epics, sprints, backlog / board cards
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS dev;

CREATE TABLE dev.projects (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  goal        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dev.scrum_teams (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id  uuid NOT NULL REFERENCES dev.projects(id) ON DELETE CASCADE,
  name        text NOT NULL
);
CREATE INDEX idx_scrum_teams_project_id ON dev.scrum_teams(project_id);
CREATE TABLE dev.team_memberships (
  scrum_team_id  uuid NOT NULL REFERENCES dev.scrum_teams(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  PRIMARY KEY (scrum_team_id, user_id)
);
CREATE INDEX idx_team_memberships_user_id ON dev.team_memberships(user_id);

CREATE TABLE dev.epics (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id  uuid NOT NULL REFERENCES dev.projects(id) ON DELETE CASCADE,
  title       text NOT NULL,
  quarter     text,                       -- 'Q3 2026'
  status      text NOT NULL DEFAULT 'planned'
);
CREATE INDEX idx_epics_project_id ON dev.epics(project_id);

CREATE TABLE dev.sprints (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id      uuid NOT NULL REFERENCES dev.projects(id) ON DELETE CASCADE,
  name            text NOT NULL,          -- 'Sprint 34'
  starts_on       date NOT NULL,
  ends_on         date NOT NULL,
  capacity_points int
);
CREATE INDEX idx_sprints_project_id ON dev.sprints(project_id);

CREATE TYPE dev.card_priority AS ENUM ('low', 'p3', 'p2', 'p1');
CREATE TYPE dev.card_status AS ENUM ('backlog', 'in_progress', 'in_review', 'done');

CREATE TABLE dev.backlog_items (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id       uuid NOT NULL REFERENCES dev.projects(id) ON DELETE CASCADE,
  card_number      text NOT NULL,          -- 'DEV-1058'
  epic_id          uuid REFERENCES dev.epics(id),
  sprint_id        uuid REFERENCES dev.sprints(id),
  title            text NOT NULL,
  tag              text,                   -- 'backend', 'frontend', 'design', 'tech-debt', ...
  points           int,
  priority         dev.card_priority NOT NULL DEFAULT 'p3',
  status           dev.card_status NOT NULL DEFAULT 'backlog',
  owner_user_id    uuid REFERENCES core.users(id),
  incident_ticket_id uuid REFERENCES itsm.tickets(id),   -- source use-case ticket, if any
  problem_id       uuid REFERENCES itsm.problems(id),     -- root-cause fix, if any
  change_request_id uuid REFERENCES itsm.change_requests(id),
  percent_complete smallint NOT NULL DEFAULT 0 CHECK (percent_complete BETWEEN 0 AND 100),
  starts_on        date,
  ends_on          date,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (card_number)
);
CREATE INDEX idx_backlog_items_owner_user_id ON dev.backlog_items(owner_user_id);
CREATE INDEX idx_backlog_items_project_id ON dev.backlog_items(project_id);
CREATE INDEX idx_backlog_items_change_request_id ON dev.backlog_items(change_request_id);
CREATE INDEX idx_backlog_items_problem_id ON dev.backlog_items(problem_id);
CREATE INDEX idx_backlog_items_incident_ticket_id ON dev.backlog_items(incident_ticket_id);
CREATE INDEX idx_backlog_items_epic_id ON dev.backlog_items(epic_id);
CREATE INDEX idx_backlog_items_sprint ON dev.backlog_items(sprint_id);
CREATE INDEX idx_backlog_items_status ON dev.backlog_items(status);
CREATE TRIGGER trg_backlog_items_updated BEFORE UPDATE ON dev.backlog_items
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Now that dev.backlog_items exists, complete the change_requests FK deferred above.
ALTER TABLE itsm.change_requests
  ADD CONSTRAINT fk_change_requests_backlog_item
  FOREIGN KEY (backlog_item_id) REFERENCES dev.backlog_items(id);

CREATE TYPE dev.environment AS ENUM ('dev', 'int', 'uat', 'pre', 'prod');

CREATE TABLE dev.deployments (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  change_request_id  uuid NOT NULL REFERENCES itsm.change_requests(id) ON DELETE CASCADE,
  environment        dev.environment NOT NULL,
  deployed_by_user_id uuid REFERENCES core.users(id),
  deployed_at        timestamptz NOT NULL DEFAULT now(),
  rolled_back_at     timestamptz
);
CREATE INDEX idx_deployments_deployed_by_user_id ON dev.deployments(deployed_by_user_id);
CREATE INDEX idx_deployments_change_request ON dev.deployments(change_request_id);


-- ============================================================================
-- SCHEMA: docs — document library, Confluence-style wiki
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS docs;

CREATE TABLE docs.folders (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_folder_id uuid REFERENCES docs.folders(id),
  name             text NOT NULL
);
CREATE INDEX idx_folders_parent_folder_id ON docs.folders(parent_folder_id);

CREATE TABLE docs.documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  folder_id     uuid REFERENCES docs.folders(id),
  name          text NOT NULL,
  content_type  text,
  size_bytes    bigint,
  storage_url   text NOT NULL,
  uploaded_by   uuid REFERENCES core.users(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_documents_uploaded_by ON docs.documents(uploaded_by);
CREATE INDEX idx_documents_folder ON docs.documents(folder_id);

CREATE TABLE docs.document_versions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id    uuid NOT NULL REFERENCES docs.documents(id) ON DELETE CASCADE,
  version_number int NOT NULL,
  storage_url    text NOT NULL,
  uploaded_by    uuid REFERENCES core.users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (document_id, version_number)
);
CREATE INDEX idx_document_versions_uploaded_by ON docs.document_versions(uploaded_by);

CREATE TABLE docs.wiki_spaces (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  description text
);

CREATE TABLE docs.wiki_pages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  space_id        uuid NOT NULL REFERENCES docs.wiki_spaces(id) ON DELETE CASCADE,
  parent_page_id  uuid REFERENCES docs.wiki_pages(id),
  title           text NOT NULL,
  body            text NOT NULL DEFAULT '',
  created_by      uuid REFERENCES core.users(id),
  updated_by      uuid REFERENCES core.users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_wiki_pages_updated_by ON docs.wiki_pages(updated_by);
CREATE INDEX idx_wiki_pages_created_by ON docs.wiki_pages(created_by);
CREATE INDEX idx_wiki_pages_parent_page_id ON docs.wiki_pages(parent_page_id);
CREATE INDEX idx_wiki_pages_space ON docs.wiki_pages(space_id);
CREATE TRIGGER trg_wiki_pages_updated BEFORE UPDATE ON docs.wiki_pages
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE docs.wiki_page_history (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wiki_page_id   uuid NOT NULL REFERENCES docs.wiki_pages(id) ON DELETE CASCADE,
  version_number int NOT NULL,
  body           text NOT NULL,
  edited_by      uuid REFERENCES core.users(id),
  edited_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (wiki_page_id, version_number)
);
CREATE INDEX idx_wiki_page_history_edited_by ON docs.wiki_page_history(edited_by);

CREATE TABLE docs.wiki_comments (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wiki_page_id   uuid NOT NULL REFERENCES docs.wiki_pages(id) ON DELETE CASCADE,
  author_user_id uuid REFERENCES core.users(id),
  body           text NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_wiki_comments_author_user_id ON docs.wiki_comments(author_user_id);
CREATE INDEX idx_wiki_comments_page ON docs.wiki_comments(wiki_page_id);


-- ============================================================================


-- ============================================================================
-- Seed: this database's own workspace row. id/tenant_id/slug must match the
-- corresponding row in trakolo-master's core.tenants exactly — that's the
-- entire link between the two databases.
-- ============================================================================
INSERT INTO core.workspace (tenant_id, name, slug, deployment_model) VALUES
  ('a1111111-1111-4111-8111-111111111111', 'Acme Corp', 'acme', 'cloud');


-- ============================================================================
-- Least-privilege application role. Run once per database, after every table
-- above exists. trakolo_app_role itself is NOLOGIN — it's a permissions
-- bundle, not something anyone connects as directly. Provisioning creates a
-- separate per-database LOGIN role (its password issued by a secrets
-- manager, never written here or committed to version control) and grants
-- it this role, e.g.: GRANT trakolo_app_role TO trakolo_app_acme;
-- Rotating that login role's password, or swapping which login role serves
-- a tenant, never means re-granting table privileges.
--
-- No CREATE/DROP/ALTER of any kind — the app cannot alter its own schema,
-- only read and write rows. Schema changes are a migration-runner concern
-- (see core.schema_migrations above), run as a separate, more privileged
-- role that the running application never uses.
-- ============================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'trakolo_app_role') THEN
    CREATE ROLE trakolo_app_role NOLOGIN;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA core, itsm, sam, dev, docs TO trakolo_app_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, itsm, sam, dev, docs TO trakolo_app_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, itsm, sam, dev, docs
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO trakolo_app_role;
