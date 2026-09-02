'use client'
import { useEffect, useState } from 'react'
export function DateTime({ value }: { value?: string | null }) {
 const [text,setText]=useState(value ? value.replace('T',' ').replace('Z',' UTC') : '—')
 useEffect(()=>{setText(value ? new Intl.DateTimeFormat(undefined,{dateStyle:'medium',timeStyle:'short'}).format(new Date(value)) : '—')},[value])
 return <time dateTime={value??undefined}>{text}</time>
}
export function localDateTime(value?:string|null){if(!value)return '';const d=new Date(value);return new Date(d.getTime()-d.getTimezoneOffset()*60000).toISOString().slice(0,16)}
