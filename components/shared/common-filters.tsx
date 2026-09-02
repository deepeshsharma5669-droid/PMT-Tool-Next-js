'use client'
import {usePathname,useRouter,useSearchParams} from 'next/navigation'
import {Icon} from '@/components/ui/icon'

export type FilterDefinition={key:string;label:string;options?:{value:string;label:string}[];type?:'text'|'date'}
export function useCommonFilters(){const params=useSearchParams(),router=useRouter(),path=usePathname();return {params,get:(key:string)=>params.get(key)??'',set:(key:string,value:string)=>{const next=new URLSearchParams(params.toString());if(value)next.set(key,value);else next.delete(key);router.replace(path+(next.size?'?'+next.toString():''),{scroll:false})},clear:()=>router.replace(path,{scroll:false})}}
export function CommonFilters({fields,results}:{fields:FilterDefinition[];results?:number}){const f=useCommonFilters(),active=fields.filter(x=>f.get(x.key)),search=fields.find(x=>!x.options&&x.type!=='date'),controls=fields.filter(x=>x!==search);return <section className="common-filters" aria-label="Filter work">
 <div className="common-filters__toolbar">{search&&<label className="common-filter-search"><span className="sr-only">{search.label}</span><Icon name="search"/><input type="text" placeholder={search.label} value={f.get(search.key)} onChange={e=>f.set(search.key,e.target.value)}/></label>}
 <div className="common-filter-controls">{controls.map(x=><label key={x.key}><span>{x.label}</span>{x.options?<select aria-label={x.label} value={f.get(x.key)} onChange={e=>f.set(x.key,e.target.value)}><option value="">All</option>{x.options.map(o=><option key={o.value} value={o.value}>{o.label}</option>)}</select>:<input aria-label={x.label} type={x.type??'text'} value={f.get(x.key)} onChange={e=>f.set(x.key,e.target.value)}/>}</label>)}</div>
 {typeof results==='number'&&<span className="common-filters__result">{results} result{results===1?'':'s'}</span>}</div>
 {active.length>0&&<div className="filter-chips"><span>Active filters</span>{active.map(x=><button key={x.key} onClick={()=>f.set(x.key,'')}>{x.label}: {x.options?.find(o=>o.value===f.get(x.key))?.label??f.get(x.key)} <b>×</b></button>)}<button className="filter-clear" onClick={f.clear}>Clear all</button></div>}
 </section>}
