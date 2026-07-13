# Trakolo — product mockups

Static HTML/CSS/JS mockups for Trakolo: an IT service desk, asset tracking (SAM), engineering boards & sprints, and audit-ready reporting, unified in one product.

**Live site:** enable GitHub Pages (Settings → Pages → Deploy from branch → `main` → `/ (root)`) and it'll be served at `https://<your-username>.github.io/<repo-name>/`.

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

## Notes

This is a static, front-end-only mockup — there's no backend, database, or auth behind any of it. Form submissions and "sign in" buttons link to other mockup pages to simulate a flow; nothing is persisted.
