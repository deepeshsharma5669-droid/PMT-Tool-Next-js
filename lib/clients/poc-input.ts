export type NewClientPoc = {
  name: string
  designation: string
  email: string
  phone: string
  whatsapp: string
  is_primary: boolean
}

// JSON is transport only. The RPC persists individual pmt_client_pocs rows.
export function prepareClientPocs(pocs: NewClientPoc[]): NewClientPoc[] {
  if (!Array.isArray(pocs)) throw new Error('POCs must be a list.')
  const normalized = pocs.map(poc => {
    if (!poc || typeof poc.name !== 'string' || !poc.name.trim())
      throw new Error('Every added POC requires a name. Remove unused POC rows.')
    return {
      name: poc.name.trim(),
      designation: String(poc.designation ?? '').trim(),
      email: String(poc.email ?? '').trim(),
      phone: String(poc.phone ?? '').trim(),
      whatsapp: String(poc.whatsapp ?? '').trim(),
      is_primary: poc.is_primary === true,
    }
  })
  if (normalized.filter(poc => poc.is_primary).length > 1)
    throw new Error('Select only one Primary POC.')
  if (normalized.length && !normalized.some(poc => poc.is_primary))
    normalized[0].is_primary = true
  return normalized
}
