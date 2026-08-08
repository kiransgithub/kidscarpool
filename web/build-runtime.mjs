import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const output = process.argv[2] || path.join(here, 'app.js')
const partsDir = path.join(here, 'app.parts')
const parts = fs.readdirSync(partsDir)
  .filter(name => name.endsWith('.js'))
  .sort((left, right) => left.localeCompare(right, 'en', { numeric: true }))

let source = parts
  .map(name => `// ---- ${name} ----\n${fs.readFileSync(path.join(partsDir, name), 'utf8')}`)
  .join('\n\n')

// Remove the retired client-side calendar template. Calendar source files,
// structured events, groups, people and schedules now come from Supabase.
source = source
  .replace(/const BASIS_CALENDAR_SHA256 = .*\n/, '')
  .replace(/const BASIS_EVENTS = \[[\s\S]*?\n\]\n\nfunction event\([\s\S]*?\n\}\n/, '')
  .replace(/p_events:\s*BASIS_EVENTS/g, 'p_events: []')

// Neutralize values retained only inside compatibility handlers for older
// cached clients. The current production path is app.parts/10+ and the final
// database-driven presentation layer.
const replacements = new Map([
  ['BASIS Phoenix Primary Carpool', 'Carpool group'],
  ['BASIS Phoenix Primary', 'Destination'],
  ['basis-phoenix-primary', 'destination'],
  ['KCP-BASIS-2026-27', 'GROUP-CODE'],
  ['KCP-PHOENIX-2026', 'GROUP-CODE'],
  ['2026-27', 'Current term'],
  ['Thanishka', 'Child'],
  ['Saanvi', 'Child'],
  ['Kavish', 'Child'],
  ['Ishi', 'Child'],
  ['Santhosh', 'Member'],
  ['Santosh', 'Member'],
  ['Pavan', 'Member'],
  ['Mohan', 'Member'],
  ['Kiran', 'Member']
])
for (const [from, to] of replacements) source = source.split(from).join(to)

const forbidden = [
  /BASIS/i,
  /KCP-BASIS/i,
  /basis-phoenix/i,
  /3a5ffb0feda17ce6a0a7655b3d6d2a9c21cbb3c473df1adcc1c8dc81ba170464/i,
  /\b(?:Thanishka|Saanvi|Kavish|Ishi|Santhosh|Santosh|Pavan|Mohan|Kiran)\b/i,
  /BASIS_EVENTS/,
  /BASIS_CALENDAR_SHA256/
]
for (const pattern of forbidden) {
  const match = source.match(pattern)
  if (match) throw new Error(`Production runtime still contains pilot data: ${match[0]}`)
}

fs.mkdirSync(path.dirname(output), { recursive: true })
fs.writeFileSync(output, source)
console.log(`Built ${output} from ${parts.length} database-driven parts`)
