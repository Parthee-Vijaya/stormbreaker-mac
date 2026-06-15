import Foundation

/// Svelte 5 + Vite + TypeScript + Tailwind CSS v4 scaffold. Verified to
/// `npm install` + `vite build` cleanly. The model authors `src/App.svelte`.
extension ProjectTemplate {
    public static let viteSvelteTailwind = ProjectTemplate(
        files: [
            File(path: "package.json", contents: sveltePackageJSON),
            File(path: "vite.config.ts", contents: svelteViteConfig),
            File(path: "svelte.config.js", contents: svelteConfigJS),
            File(path: "index.html", contents: svelteIndexHTML),
            File(path: "src/main.ts", contents: svelteMainTS),
            File(path: "src/App.svelte", contents: svelteAppSvelte),
            File(path: "src/app.css", contents: svelteAppCSS),
            File(path: "src/vite-env.d.ts", contents: svelteEnvDTS),
            File(path: ".gitignore", contents: frameworkGitignore),
        ],
        modelEntryFile: "src/App.svelte"
    )
}

private let sveltePackageJSON = """
{
  "name": "forge-app",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "svelte": "^5.0.0"
  },
  "devDependencies": {
    "@sveltejs/vite-plugin-svelte": "^5.0.0",
    "@tailwindcss/vite": "^4.0.0",
    "tailwindcss": "^4.0.0",
    "typescript": "^5.6.0",
    "vite": "^6.0.0"
  }
}
"""

private let svelteViteConfig = """
import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import tailwindcss from '@tailwindcss/vite'

// strictPort is false so Vite recovers to the next free port; --host (passed by
// Forge) binds LAN interfaces for the shared live link.
export default defineConfig({
  plugins: [svelte(), tailwindcss()],
  server: { host: '127.0.0.1', strictPort: false },
})
"""

private let svelteConfigJS = """
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte'

export default { preprocess: vitePreprocess() }
"""

private let svelteIndexHTML = """
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Forge App</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>
"""

private let svelteMainTS = """
import { mount } from 'svelte'
import './app.css'
import App from './App.svelte'

const app = mount(App, { target: document.getElementById('app')! })

export default app
"""

private let svelteAppSvelte = """
<script lang="ts">
  let count = $state(0)
</script>

<main class="min-h-screen flex items-center justify-center bg-white text-neutral-900">
  <button
    class="px-5 py-2.5 rounded-lg bg-black text-white font-medium hover:bg-neutral-800"
    onclick={() => count++}
  >
    Clicked {count} times
  </button>
</main>
"""

private let svelteAppCSS = """
@import "tailwindcss";
"""

private let svelteEnvDTS = """
/// <reference types="svelte" />
/// <reference types="vite/client" />
"""
