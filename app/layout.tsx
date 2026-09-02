import './globals.css'

export const metadata = {
  title: 'TheFinPedia PMT',
  description: 'Professional project and production management workspace.',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
