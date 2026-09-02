import type { ReactNode } from 'react'

export function SectionCard({ title, description, action, children, className = '' }: { title: string; description?: string; action?: ReactNode; children: ReactNode; className?: string }) {
  return <section className={`section-card ${className}`}><header className="section-card__header"><div><h2>{title}</h2>{description&&<p>{description}</p>}</div>{action}</header><div className="section-card__body">{children}</div></section>
}

export function StatTile({ label, value, detail, tone = 'default' }: { label: string; value: ReactNode; detail?: ReactNode; tone?: 'default'|'purple'|'warning'|'danger'|'success' }) {
  return <div className={`stat-tile stat-tile--${tone}`}><div className="stat-tile__label"><span className="stat-tile__mark"/>{label}</div><strong>{value}</strong>{detail&&<small>{detail}</small>}</div>
}
