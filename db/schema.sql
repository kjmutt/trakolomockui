-- ============================================================================
-- Trakolo — relational database schema (PostgreSQL 14+)
--
-- Mirrors the modular-monolith architecture: one database, one schema per
-- product module (core, itsm, sam, dev, docs, platform), not one schema per
-- microservice. Every tenant-owned table carries tenant_id and is scoped by
-- it — this is a shared-database, row-level multi-tenancy model (see
-- core.tenants). Split a module into its own service later only if it earns
-- that separately; the schema boundary already makes that split possible
-- without a rewrite.
--
-- Apply with:  psql -d trakolo -f db/schema.sql
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

CREATE TABLE core.tenants (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL,
  slug         text NOT NULL UNIQUE,
  edition      text NOT NULL DEFAULT 'cloud' CHECK (edition IN ('cloud', 'standalone')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_tenants_updated BEFORE UPDATE ON core.tenants
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TYPE core.user_status AS ENUM ('active', 'invited', 'suspended');

CREATE TABLE core.users (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  email            citext NOT NULL,
  name             text NOT NULL,
  avatar_initials  text,
  status           core.user_status NOT NULL DEFAULT 'invited',
  last_login_at    timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, email)
);
CREATE INDEX idx_users_tenant ON core.users(tenant_id);
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON core.users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Contacts are SSP/end-user requesters (Section: Contacts directory) — a
-- distinct population from core.users, who are internal agents/admins.
CREATE TABLE core.contacts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  email       citext NOT NULL,
  department  text,
  title       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, email)
);
CREATE INDEX idx_contacts_tenant ON core.contacts(tenant_id);

CREATE TABLE core.roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,               -- Admin, Manager, Agent, Viewer, or a custom role
  is_system   boolean NOT NULL DEFAULT false,
  UNIQUE (tenant_id, name)
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

CREATE TABLE core.user_roles (
  user_id  uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  role_id  uuid NOT NULL REFERENCES core.roles(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);

-- Support groups (e.g. "IT Ops", "Infrastructure", "Security")
CREATE TABLE core.teams (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  UNIQUE (tenant_id, name)
);
CREATE TABLE core.team_members (
  team_id  uuid NOT NULL REFERENCES core.teams(id) ON DELETE CASCADE,
  user_id  uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  PRIMARY KEY (team_id, user_id)
);

-- Approval groups (used by change requests, access requests, catalog items)
CREATE TABLE core.approval_groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  UNIQUE (tenant_id, name)
);
CREATE TABLE core.approval_group_members (
  approval_group_id  uuid NOT NULL REFERENCES core.approval_groups(id) ON DELETE CASCADE,
  user_id            uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  PRIMARY KEY (approval_group_id, user_id)
);

CREATE TABLE core.notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
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
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  key_hash    text NOT NULL,               -- never store the raw key
  scopes      text[] NOT NULL DEFAULT '{}',
  created_by  uuid REFERENCES core.users(id),
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_api_keys_tenant ON core.api_keys(tenant_id);

CREATE TABLE core.integrations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  provider         text NOT NULL,          -- 'slack', 'github', 'okta', 'jira', ...
  status           text NOT NULL DEFAULT 'not_connected',
  config           jsonb NOT NULL DEFAULT '{}',
  last_synced_at   timestamptz,
  UNIQUE (tenant_id, provider)
);

CREATE TABLE core.feature_flags (
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  feature_key text NOT NULL,               -- 'knowledge_base', 'ai_copilot', 'change_management', ...
  enabled     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (tenant_id, feature_key)
);

-- Every admin action and privileged change — see Admin > Audit log.
CREATE TABLE core.audit_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  actor_user_id uuid REFERENCES core.users(id),
  action       text NOT NULL,              -- 'role.updated', 'business_rule.created', ...
  target_type  text NOT NULL,
  target_id    uuid,
  metadata     jsonb NOT NULL DEFAULT '{}',
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_log_tenant_time ON core.audit_log(tenant_id, created_at DESC);


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
-- self-referencing pattern as docs.folders. One tenant's category tree is
-- independent of another's.
CREATE TABLE itsm.ticket_categories (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  parent_category_id  uuid REFERENCES itsm.ticket_categories(id),
  name                text NOT NULL,
  sort_order          int NOT NULL DEFAULT 0
);
CREATE INDEX idx_ticket_categories_parent ON itsm.ticket_categories(parent_category_id);
CREATE INDEX idx_ticket_categories_tenant ON itsm.ticket_categories(tenant_id);

CREATE TABLE itsm.tickets (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
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
  UNIQUE (tenant_id, ticket_number)
);
CREATE INDEX idx_tickets_tenant_status ON itsm.tickets(tenant_id, status);
CREATE INDEX idx_tickets_assignee ON itsm.tickets(assignee_user_id);
CREATE INDEX idx_tickets_category ON itsm.tickets(category_id);
CREATE INDEX idx_tickets_sla_due ON itsm.tickets(sla_due_at) WHERE status NOT IN ('resolved', 'closed', 'merged');
CREATE TRIGGER trg_tickets_updated BEFORE UPDATE ON itsm.tickets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TYPE itsm.actor_type AS ENUM ('user', 'contact', 'ai_agent', 'system');

CREATE TABLE itsm.ticket_activity (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  ticket_id    uuid NOT NULL REFERENCES itsm.tickets(id) ON DELETE CASCADE,
  actor_type   itsm.actor_type NOT NULL,
  actor_user_id uuid REFERENCES core.users(id),
  actor_label  text,                       -- fallback display name (e.g. 'Trakolo AI agent')
  body         text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ticket_activity_ticket ON itsm.ticket_activity(ticket_id, created_at);

CREATE TABLE itsm.ticket_attachments (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  ticket_id     uuid NOT NULL REFERENCES itsm.tickets(id) ON DELETE CASCADE,
  filename      text NOT NULL,
  content_type  text,
  size_bytes    bigint,
  storage_url   text NOT NULL,
  uploaded_by   uuid REFERENCES core.users(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ticket_attachments_ticket ON itsm.ticket_attachments(ticket_id);

-- Generic cross-module links (ticket <-> ticket, ticket <-> dev card, ticket
-- <-> change request). linked_type + linked_id is a loose polymorphic
-- reference by design — the alternative (one FK column per linkable type)
-- doesn't scale as new modules link into tickets.
CREATE TABLE itsm.ticket_links (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
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
  tenant_id      uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  problem_number text NOT NULL,            -- 'PRB-0007'
  title          text NOT NULL,
  status         itsm.problem_status NOT NULL DEFAULT 'open',
  root_cause     text,
  workaround     text,
  owner_user_id  uuid REFERENCES core.users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  closed_at      timestamptz,
  UNIQUE (tenant_id, problem_number)
);
CREATE TABLE itsm.problem_incidents (
  problem_id  uuid NOT NULL REFERENCES itsm.problems(id) ON DELETE CASCADE,
  ticket_id   uuid NOT NULL REFERENCES itsm.tickets(id) ON DELETE CASCADE,
  PRIMARY KEY (problem_id, ticket_id)
);

CREATE TYPE itsm.change_status AS ENUM ('draft', 'pending_approval', 'approved', 'rejected', 'deployed', 'rolled_back');
CREATE TYPE itsm.change_risk AS ENUM ('low', 'medium', 'high');

CREATE TABLE itsm.change_requests (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
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
  UNIQUE (tenant_id, cr_number)
);
CREATE INDEX idx_change_requests_status ON itsm.change_requests(tenant_id, status);

CREATE TYPE itsm.approval_decision AS ENUM ('pending', 'approved', 'rejected');

CREATE TABLE itsm.change_approvals (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  change_request_id  uuid NOT NULL REFERENCES itsm.change_requests(id) ON DELETE CASCADE,
  approval_group_id  uuid REFERENCES core.approval_groups(id),
  approver_user_id   uuid REFERENCES core.users(id),
  decision           itsm.approval_decision NOT NULL DEFAULT 'pending',
  comment            text,
  decided_at         timestamptz
);

CREATE TABLE itsm.sla_policies (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  priority          itsm.priority NOT NULL,
  response_minutes  int NOT NULL,
  resolution_minutes int NOT NULL,
  UNIQUE (tenant_id, priority)
);

CREATE TABLE itsm.business_rules (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  trigger     text NOT NULL,               -- 'ticket.created', 'ticket.escalated', ...
  conditions  jsonb NOT NULL DEFAULT '[]',
  actions     jsonb NOT NULL DEFAULT '[]',
  run_order   int NOT NULL DEFAULT 0,
  enabled     boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_business_rules_tenant_order ON itsm.business_rules(tenant_id, run_order);

CREATE TABLE itsm.service_catalog_categories (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  parent_category_id  uuid REFERENCES itsm.service_catalog_categories(id),
  name                text NOT NULL,
  sort_order          int NOT NULL DEFAULT 0
);
CREATE INDEX idx_service_catalog_categories_parent ON itsm.service_catalog_categories(parent_category_id);
CREATE INDEX idx_service_catalog_categories_tenant ON itsm.service_catalog_categories(tenant_id);

CREATE TABLE itsm.service_catalog_items (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
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
  tenant_id           uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  catalog_item_id     uuid NOT NULL REFERENCES itsm.service_catalog_items(id),
  requested_by_contact_id uuid REFERENCES core.contacts(id),
  ticket_id           uuid REFERENCES itsm.tickets(id),
  status              itsm.ticket_status NOT NULL DEFAULT 'open',
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE itsm.kb_categories (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  parent_category_id  uuid REFERENCES itsm.kb_categories(id),
  name                text NOT NULL,
  sort_order          int NOT NULL DEFAULT 0
);
CREATE INDEX idx_kb_categories_parent ON itsm.kb_categories(parent_category_id);
CREATE INDEX idx_kb_categories_tenant ON itsm.kb_categories(tenant_id);

CREATE TABLE itsm.kb_articles (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
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
  tenant_id          uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name               text NOT NULL,
  escalation_policy  jsonb NOT NULL DEFAULT '{}'  -- L1 -> L2 -> L3 timing/paging rules
);
CREATE TABLE itsm.oncall_rotations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  schedule_id  uuid NOT NULL REFERENCES itsm.oncall_schedules(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES core.users(id),
  starts_at    timestamptz NOT NULL,
  ends_at      timestamptz NOT NULL
);
CREATE INDEX idx_oncall_rotations_window ON itsm.oncall_rotations(schedule_id, starts_at, ends_at);


-- ============================================================================
-- SCHEMA: sam — software & hardware asset management
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS sam;

CREATE TYPE sam.asset_type AS ENUM ('hardware', 'software', 'license', 'mobile');
CREATE TYPE sam.asset_status AS ENUM ('active', 'in_repair', 'idle', 'retired');

CREATE TABLE sam.assets (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
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
  UNIQUE (tenant_id, asset_tag)
);
CREATE INDEX idx_assets_tenant_type ON sam.assets(tenant_id, type);
CREATE INDEX idx_assets_renews_at ON sam.assets(renews_at) WHERE status = 'active';
CREATE TRIGGER trg_assets_updated BEFORE UPDATE ON sam.assets
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE sam.asset_assignments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  asset_id        uuid NOT NULL REFERENCES sam.assets(id) ON DELETE CASCADE,
  assigned_to_user_id uuid NOT NULL REFERENCES core.users(id),
  assigned_at     timestamptz NOT NULL DEFAULT now(),
  unassigned_at   timestamptz
);
CREATE INDEX idx_asset_assignments_asset ON sam.asset_assignments(asset_id);

CREATE TYPE sam.renewal_status AS ENUM ('upcoming', 'renewed', 'reclaimed', 'lapsed');

CREATE TABLE sam.license_renewals (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  asset_id      uuid NOT NULL REFERENCES sam.assets(id) ON DELETE CASCADE,
  renews_at     date NOT NULL,
  value         numeric(12,2),
  status        sam.renewal_status NOT NULL DEFAULT 'upcoming',
  reminder_sent_at timestamptz
);
CREATE INDEX idx_license_renewals_due ON sam.license_renewals(renews_at) WHERE status = 'upcoming';

CREATE TYPE sam.scan_type AS ENUM ('agent', 'network');
CREATE TYPE sam.scan_status AS ENUM ('running', 'completed', 'failed');

CREATE TABLE sam.discovery_scans (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
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
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  goal        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dev.scrum_teams (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  project_id  uuid NOT NULL REFERENCES dev.projects(id) ON DELETE CASCADE,
  name        text NOT NULL
);
CREATE TABLE dev.team_memberships (
  scrum_team_id  uuid NOT NULL REFERENCES dev.scrum_teams(id) ON DELETE CASCADE,
  user_id        uuid NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
  PRIMARY KEY (scrum_team_id, user_id)
);

CREATE TABLE dev.epics (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  project_id  uuid NOT NULL REFERENCES dev.projects(id) ON DELETE CASCADE,
  title       text NOT NULL,
  quarter     text,                       -- 'Q3 2026'
  status      text NOT NULL DEFAULT 'planned'
);

CREATE TABLE dev.sprints (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  project_id      uuid NOT NULL REFERENCES dev.projects(id) ON DELETE CASCADE,
  name            text NOT NULL,          -- 'Sprint 34'
  starts_on       date NOT NULL,
  ends_on         date NOT NULL,
  capacity_points int
);

CREATE TYPE dev.card_priority AS ENUM ('low', 'p3', 'p2', 'p1');
CREATE TYPE dev.card_status AS ENUM ('backlog', 'in_progress', 'in_review', 'done');

CREATE TABLE dev.backlog_items (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
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
  UNIQUE (tenant_id, card_number)
);
CREATE INDEX idx_backlog_items_sprint ON dev.backlog_items(sprint_id);
CREATE INDEX idx_backlog_items_status ON dev.backlog_items(tenant_id, status);
CREATE TRIGGER trg_backlog_items_updated BEFORE UPDATE ON dev.backlog_items
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Now that dev.backlog_items exists, complete the change_requests FK deferred above.
ALTER TABLE itsm.change_requests
  ADD CONSTRAINT fk_change_requests_backlog_item
  FOREIGN KEY (backlog_item_id) REFERENCES dev.backlog_items(id);

CREATE TYPE dev.environment AS ENUM ('dev', 'int', 'uat', 'pre', 'prod');

CREATE TABLE dev.deployments (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  change_request_id  uuid NOT NULL REFERENCES itsm.change_requests(id) ON DELETE CASCADE,
  environment        dev.environment NOT NULL,
  deployed_by_user_id uuid REFERENCES core.users(id),
  deployed_at        timestamptz NOT NULL DEFAULT now(),
  rolled_back_at     timestamptz
);
CREATE INDEX idx_deployments_change_request ON dev.deployments(change_request_id);


-- ============================================================================
-- SCHEMA: docs — document library, Confluence-style wiki
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS docs;

CREATE TABLE docs.folders (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  parent_folder_id uuid REFERENCES docs.folders(id),
  name             text NOT NULL
);

CREATE TABLE docs.documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  folder_id     uuid REFERENCES docs.folders(id),
  name          text NOT NULL,
  content_type  text,
  size_bytes    bigint,
  storage_url   text NOT NULL,
  uploaded_by   uuid REFERENCES core.users(id),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_documents_folder ON docs.documents(folder_id);

CREATE TABLE docs.document_versions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  document_id    uuid NOT NULL REFERENCES docs.documents(id) ON DELETE CASCADE,
  version_number int NOT NULL,
  storage_url    text NOT NULL,
  uploaded_by    uuid REFERENCES core.users(id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (document_id, version_number)
);

CREATE TABLE docs.wiki_spaces (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  description text
);

CREATE TABLE docs.wiki_pages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  space_id        uuid NOT NULL REFERENCES docs.wiki_spaces(id) ON DELETE CASCADE,
  parent_page_id  uuid REFERENCES docs.wiki_pages(id),
  title           text NOT NULL,
  body            text NOT NULL DEFAULT '',
  created_by      uuid REFERENCES core.users(id),
  updated_by      uuid REFERENCES core.users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_wiki_pages_space ON docs.wiki_pages(space_id);
CREATE TRIGGER trg_wiki_pages_updated BEFORE UPDATE ON docs.wiki_pages
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE docs.wiki_page_history (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  wiki_page_id   uuid NOT NULL REFERENCES docs.wiki_pages(id) ON DELETE CASCADE,
  version_number int NOT NULL,
  body           text NOT NULL,
  edited_by      uuid REFERENCES core.users(id),
  edited_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (wiki_page_id, version_number)
);

CREATE TABLE docs.wiki_comments (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  wiki_page_id   uuid NOT NULL REFERENCES docs.wiki_pages(id) ON DELETE CASCADE,
  author_user_id uuid REFERENCES core.users(id),
  body           text NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_wiki_comments_page ON docs.wiki_comments(wiki_page_id);


-- ============================================================================
-- SCHEMA: platform — Trakolo-staff-only: plans, subscriptions, entitlements,
-- cross-tenant service health. Everything here is written by platform admins
-- (saas-admin-console.html), never by tenant users.
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS platform;

CREATE TABLE platform.plans (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text NOT NULL UNIQUE,     -- 'Free', 'Team', 'Business', 'Enterprise'
  price_monthly  numeric(10,2),
  seat_based     boolean NOT NULL DEFAULT true,
  features       jsonb NOT NULL DEFAULT '{}'
);

CREATE TYPE platform.subscription_status AS ENUM ('trialing', 'active', 'past_due', 'canceled');

CREATE TABLE platform.subscriptions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES core.tenants(id) ON DELETE CASCADE,
  plan_id      uuid NOT NULL REFERENCES platform.plans(id),
  status       platform.subscription_status NOT NULL DEFAULT 'trialing',
  seats        int NOT NULL DEFAULT 1,
  started_at   timestamptz NOT NULL DEFAULT now(),
  renews_at    timestamptz,
  UNIQUE (tenant_id)                       -- one active subscription per tenant
);

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


-- ============================================================================
-- Seed: one demo tenant, matching the mockup's "Acme Corp" workspace
-- ============================================================================
INSERT INTO core.tenants (name, slug, edition) VALUES ('Acme Corp', 'acme', 'cloud');
