# Trakolo — product mockups

Static HTML/CSS/JS mockups for Trakolo: an IT service desk, asset tracking (SAM), engineering boards & sprints, and audit-ready reporting, unified in one product.

**Live site:** https://kjmutt.github.io/trakolomockui/ — GitHub Pages is configured to deploy from the `main` branch, so every push to `main` republishes it. There's no workflow file; Pages does this itself.

**Viewing it locally:** clone the repo and open any `.html` file directly. There's no build step and nothing is fetched cross-origin, so `file://` works without a server.

## Structure

- `index.html` — sitemap of every page in this repo
- `site/` — the public marketing website (homepage, features, how it works, integrations, pricing, docs)
- `login.html` — sign-in chooser, routes to one of four login flows:
  - `ssp-login.html` — employee self-service portal login
  - `agent-login.html` — internal agent login (service desk, assets, boards, reporting)
  - `portal-admin-login.html` — tenant admin login (SSO + 2FA)
  - `saas-admin-login.html` → `saas-admin-console.html` — Trakolo staff-only platform console across all tenants
- `desk-log-ticket.html`, `desk.html` — service desk (ticket logging, queue + detail)
- `sam.html`, `sam-renewals.html` — asset tracking
- `dev.html`, `dev-backlog.html` — boards & sprints
- `ops.html`, `ops-compliance-audit.html` — reporting
- `admin.html` — workspace settings (SLAs, routing, users, portal config)
- `contact.html`, `track.html` — public support pages
- `styles.css` — shared design system (design tokens, components)
- `db/schema.sql` — PostgreSQL schema applied once per cloud tenant's own dedicated database, and identically for a standalone/on-premise install (tickets, problems, changes, CMDB, assets, sprints, docs/wiki, identity & roles) — no `tenant_id` column, the database itself is the tenant boundary
- `db/schema-master.sql` — Trakolo's own control-plane database ("trakolo-master"): the tenant registry (which database and subdomain each cloud tenant routes to) plus every table behind the Platform Admin console (plans, subscriptions, leads, campaigns, error log)

## Notes

This is a static, front-end-only mockup — there's no backend or auth behind any of it. Form submissions and "sign in" buttons link to other mockup pages to simulate a flow; nothing is persisted. `db/schema.sql` and `db/schema-master.sql` are forward-looking companion pieces, not something the mockup runs against.
