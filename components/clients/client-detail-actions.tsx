'use client'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import type { ClientRecord } from '@/lib/clients/data'
import { updateClient } from '@/app/actions/clients'

export function ClientDetailActions({ client }: { client: ClientRecord }) {
  const router = useRouter()
  const [open, setOpen] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [pending, start] = useTransition()
  function edit(fd: FormData) {
    start(async () => {
      const result = await updateClient(client.id, {
        name: String(fd.get('name')).trim(), contact: String(fd.get('contact')).trim(),
        email: String(fd.get('email')).trim(), phone: String(fd.get('phone')).trim(),
        whatsapp: String(fd.get('whatsapp')).trim(),
      })
      setMessage(result.success ? 'Client updated successfully.' : result.error)
      if (result.success) { setOpen(false); router.refresh() }
    })
  }
  return <>
    {!open && message && <div className="action-feedback" role="status">{message}</div>}
    <div className="detail-actions"><button className="button" onClick={() => { setMessage(null); setOpen(true) }}>Edit Client</button></div>
    {open && <div className="drawer-scrim" onMouseDown={() => { if (!pending) setOpen(false) }}>
      <aside className="task-drawer" role="dialog" aria-modal="true" aria-labelledby="edit-client-title" onMouseDown={e => e.stopPropagation()}>
        <header><div><span className="eyebrow">Client organization</span><h2 id="edit-client-title">Edit Client</h2></div>
          <button disabled={pending} onClick={() => setOpen(false)} aria-label="Close">×</button></header>
        <form action={edit}>
          {message && <div className="action-feedback" role="alert">{message}</div>}
          <label>Name *<input name="name" required defaultValue={client.name}/></label>
          <label>Contact information<input name="contact" defaultValue={client.contact ?? ''}/></label>
          <label>Email<input name="email" type="email" defaultValue={client.email ?? ''}/></label>
          <label>Phone<input name="phone" defaultValue={client.phone ?? ''}/></label>
          <label>WhatsApp<input name="whatsapp" defaultValue={client.whatsapp ?? ''}/></label>
          <footer><button type="button" className="button" disabled={pending} onClick={() => setOpen(false)}>Cancel</button>
            <button className="button button--primary" disabled={pending}>{pending ? 'Saving…' : 'Save changes'}</button></footer>
        </form>
      </aside>
    </div>}
  </>
}
