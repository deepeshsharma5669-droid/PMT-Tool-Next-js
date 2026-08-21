# PMT Next.js — Legacy Parity Build

## What this does right now
`app/page.tsx` embeds your original `5.html` prototype (copied byte-for-byte
into `public/pmt-legacy.html`) inside an iframe that fills the whole window.

This means:
- **100% identical behavior** to the HTML file you uploaded — every render
  function, every modal, the kanban drag-and-drop, the efficiency calculator,
  the campaign wizard — all run exactly as they did before, unchanged.
- It's now a real Next.js project, so it **deploys properly** (Vercel,
  Netlify, etc.) instead of being a loose file someone has to double-click.
- Nothing is rewritten or at risk of behaving differently — it's the same
  file, just served through a real app shell.

## What it does NOT do yet
- No backend. `public/pmt-legacy.html` still uses the in-memory `DB` object —
  refreshing the page resets all data, and nothing is shared between users.
- Also still no auth — the role switcher dropdown is the same trust-the-client
  mechanism as before.

## Why this approach, instead of a full rewrite
Rewriting all 3,842 lines into React components + Supabase calls in one pass
risks introducing bugs that are hard to catch without testing every screen
individually. This iframe bridge gets you deployed and running today with
zero behavior risk, so you have a stable baseline while we migrate.

## Real migration path from here
Convert one section at a time out of the iframe and into real Next.js/React,
verifying each one before moving to the next:

1. Dashboard — stat cards, pipeline bar, manager/member efficiency tables.
2. Campaigns / Deliverables / Stages — real routes reading from Supabase
   instead of the DB object.
3. Kanban board — client component with drag handlers calling Server
   Actions instead of mutating DB.tasks directly.
4. Task/feedback/client-changes modals — real React modals with form
   Server Actions instead of document.getElementById reads.
5. Efficiency calculator — Supabase-backed calculation, modal converted
   to React.
6. Auth — replace the role-switcher dropdown with real Supabase Auth + RLS.

Each of these can be requested one at a time, same as Clients/Users/Leaves
in pmt-thefinpedia: real page, real Supabase table, real Server Action,
verified working before moving to the next piece.

## Run it
```
npm install
npm run dev
```
Visit http://localhost:3000 — you should see the exact same app as 5.html,
running inside Next.js.
