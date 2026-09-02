'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/app/actions/clients'
import type { NewClientPoc } from '@/lib/clients/poc-input'

const blankPoc = (): NewClientPoc => ({
  name: '', designation: '', email: '', phone: '', whatsapp: '', is_primary: false,
})

export function NewClient() {
  const router = useRouter()
  const [open, setOpen] = useState(false)
  const [pocs, setPocs] = useState<(NewClientPoc & { key: number })[]>([])
  const [nextKey, setNextKey] = useState(0)
  const [message, setMessage] = useState<string | null>(null)
  const [pending, start] = useTransition()
  function addPoc() {
    setPocs(rows => [...rows, { ...blankPoc(), key: nextKey, is_primary: rows.length === 0 }])
    setNextKey(value => value + 1)
  }
  function submit(fd: FormData) {
    start(async () => {
      const result = await createClient({
        name: String(fd.get('name')).trim(), contact: '',
        email: String(fd.get('email')).trim(), phone: String(fd.get('phone')).trim(),
        whatsapp: String(fd.get('whatsapp')).trim(),
      }, pocs)
      if (!result.success) { setMessage(result.error); return }
      setOpen(false)
      setPocs([])
      setMessage(null)
      router.push(`/clients/${result.data.id}`)
      router.refresh()
    })
  }
  return <>
    <div className="page-primary-actions">
      <button className="button button--primary" onClick={() => { setMessage(null); setOpen(true) }}>+ New Client</button>
    </div>
    {open && <div className="drawer-scrim" onMouseDown={() => { if (!pending) setOpen(false) }}>
      <aside className="task-drawer" role="dialog" aria-modal="true" aria-labelledby="new-client-title" onMouseDown={e => e.stopPropagation()}>
        <header><div><span className="eyebrow">Client organization</span><h2 id="new-client-title">New Client</h2></div>
          <button disabled={pending} onClick={() => setOpen(false)} aria-label="Close">×</button>
        </header>
        <form action={submit}>
          {message && <div className="action-feedback" role="alert">{message}</div>}
          <fieldset disabled={pending}>
            <legend>Client information</legend>
            <label>Name *<input name="name" required maxLength={160}/></label>
            <label>Email<input name="email" type="email"/></label>
            <label>Phone<input name="phone"/></label>
            <label>WhatsApp<input name="whatsapp"/></label>
          </fieldset>
          <fieldset disabled={pending}>
            <legend>Client POCs — Optional</legend>
            <p className="form-hint">Create this Client without contacts, or add POCs now. You can add and manage POCs on Client Detail later.</p>
            {pocs.map((poc, index) => <fieldset key={poc.key}>
              <legend>POC {index + 1}</legend>
              {(['name', 'designation', 'email', 'phone', 'whatsapp'] as const).map(field => <label key={field}>
                {field === 'name' ? 'POC name *' : field === 'whatsapp' ? 'WhatsApp' : field.charAt(0).toUpperCase() + field.slice(1)}
                <input required={field === 'name'} type={field === 'email' ? 'email' : 'text'} value={poc[field]}
                  onChange={e => setPocs(rows => rows.map(row => row.key === poc.key ? { ...row, [field]: e.target.value } : row))}/>
              </label>)}
              <label className="check-row"><input type="radio" name="primary-poc" checked={poc.is_primary}
                onChange={() => setPocs(rows => rows.map(row => ({ ...row, is_primary: row.key === poc.key })))}/>Primary POC</label>
              <button type="button" className="button" onClick={() => setPocs(rows => {
                const remaining = rows.filter(row => row.key !== poc.key)
                return remaining.map((row, i) => ({ ...row, is_primary: row.is_primary || (poc.is_primary && i === 0) }))
              })}>Remove POC {index + 1}</button>
            </fieldset>)}
            <button type="button" className="button" onClick={addPoc}>{pocs.length ? '+ Add another POC' : '+ Add POC'}</button>
          </fieldset>
          <footer><button type="button" className="button" disabled={pending} onClick={() => setOpen(false)}>Cancel</button>
            <button className="button button--primary" disabled={pending}>{pending ? 'Creating…' : 'Create Client'}</button></footer>
        </form>
      </aside>
    </div>}
  </>
}
