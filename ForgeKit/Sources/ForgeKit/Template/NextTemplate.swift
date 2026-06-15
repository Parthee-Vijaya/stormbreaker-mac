import Foundation

/// Next.js 15 (App Router) + TypeScript + Tailwind CSS v4 scaffold (B7). Unlike the
/// Vite frameworks this runs `next dev` (port 3000) — but Next prints the same
/// "Local: http://localhost:…" ready line, so DevServerManager's generic
/// `npm run dev` + ViteReadyDetector path carries it. The model authors
/// `app/page.tsx`. `next-env.d.ts` is included so the `tsc --noEmit` gate works
/// before Next generates it on first run.
///
/// Basic Next.js support — a clean scaffold that installs + runs. Next-specific
/// error formats, the type-check story, and server-component nuances are left to
/// harden later (it reuses the Vite-tuned gates for now).
extension ProjectTemplate {
    public static let nextjsTailwind = ProjectTemplate(
        files: [
            File(path: "package.json", contents: nextPackageJSON),
            File(path: "next.config.mjs", contents: nextConfigMJS),
            File(path: "postcss.config.mjs", contents: nextPostcssMJS),
            File(path: "tsconfig.json", contents: nextTSConfig),
            File(path: "next-env.d.ts", contents: nextEnvDTS),
            File(path: "app/layout.tsx", contents: nextLayoutTSX),
            File(path: "app/page.tsx", contents: nextPageTSX),
            File(path: "app/globals.css", contents: nextGlobalsCSS),
            File(path: ".gitignore", contents: nextGitignore),
        ],
        modelEntryFile: "app/page.tsx"
    )
}

private let nextPackageJSON = """
{
  "name": "forge-app",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "next lint"
  },
  "dependencies": {
    "next": "^15.1.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "lucide-react": "^0.460.0"
  },
  "devDependencies": {
    "@tailwindcss/postcss": "^4.0.0",
    "tailwindcss": "^4.0.0",
    "typescript": "^5.6.0",
    "@types/node": "^22.0.0",
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0"
  }
}
"""

private let nextConfigMJS = """
/** @type {import('next').NextConfig} */
const nextConfig = {}
export default nextConfig
"""

private let nextPostcssMJS = """
const config = {
  plugins: {
    "@tailwindcss/postcss": {},
  },
}
export default config
"""

private let nextTSConfig = """
{
  "compilerOptions": {
    "target": "ES2017",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": { "@/*": ["./*"] }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
"""

private let nextEnvDTS = """
/// <reference types="next" />
/// <reference types="next/image-types/global" />

// NOTE: This file should not be edited.
"""

private let nextLayoutTSX = """
import type { Metadata } from "next"
import "./globals.css"

export const metadata: Metadata = {
  title: "Forge App",
  description: "Bygget med Forge",
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="da">
      <body>{children}</body>
    </html>
  )
}
"""

private let nextPageTSX = """
export default function Page() {
  return (
    <main className="min-h-screen flex items-center justify-center bg-white text-gray-900">
      <div className="text-center">
        <h1 className="text-3xl font-semibold">Din Next.js-app er klar 🚀</h1>
        <p className="mt-2 text-gray-500">Beskriv en ændring, så bygger jeg videre.</p>
      </div>
    </main>
  )
}
"""

private let nextGlobalsCSS = """
@import "tailwindcss";
"""

private let nextGitignore = """
node_modules
.next
out
dist
.DS_Store
*.log
.env*.local
.vercel
"""
