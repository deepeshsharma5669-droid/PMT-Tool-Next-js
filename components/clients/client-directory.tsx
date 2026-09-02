'use client'
import { useMemo, useState } from 'react'
import Link from 'next/link'
import type { ClientRecord } from '@/lib/clients/data'
import { EmptyState } from '@/components/shared/states'
import { NewClient } from './new-client'

export function ClientDirectory({ clients }: { clients: ClientRecord[] }) {
  const [q, setQ] = useState('')
  const rows = useMemo(() => clients.filter(c =>
    (c.name + ' ' + (c.email ?? '') + ' ' + (c.contact ?? '')).toLowerCase().includes(q.toLowerCase())
  ), [clients, q])
  return <>
    <NewClient/>
    <div className="filter-bar"><label className="filter-search"><span>⌕</span>
      <input value={q} onChange={e => setQ(e.target.value)} placeholder="Search clients"/>
    </label><span className="filter-count">{rows.length} client{rows.length === 1 ? '' : 's'}</span></div>
    {rows.length ? <div className="client-grid">{rows.map(c =>
      <Link href={`/clients/${c.id}`} className="client-card" key={c.id}>
        <header><div><small>Client organization</small><h2>{c.name}</h2></div></header>
        <dl><div><dt>Email</dt><dd>{c.email ?? '—'}</dd></div><div><dt>Phone</dt><dd>{c.phone ?? '—'}</dd></div>
          <div><dt>WhatsApp</dt><dd>{c.whatsapp ?? '—'}</dd></div></dl>
        <footer>{c.campaignCount} Project{c.campaignCount === 1 ? '' : 's'}<span>Open →</span></footer>
      </Link>)}</div> : <EmptyState title="No clients found." description={clients.length ? 'Try changing the search.' : 'Create the first Client. POCs can be added now or later.'}/>}
  </>
}
