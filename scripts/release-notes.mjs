import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** The `## <version>` section body from a changesets-generated CHANGELOG.
 *  Matches the whole heading line — `indexOf` would hit `## x-alpha.10`
 *  when looking for `## x-alpha.1`. */
export const changelogSection = (changelog, version) => {
  const esc = version.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const heading = new RegExp(`^## ${esc}$`, 'm')
  const m = heading.exec(changelog)
  if (!m) throw new Error(`no "## ${version}" section in the changelog`)
  const bodyStart = m.index + m[0].length + 1
  const next = changelog.indexOf('\n## ', bodyStart)
  return changelog.slice(bodyStart, next === -1 ? undefined : next + 1).trim()
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const version = process.argv[2]
  if (!version) throw new Error('release-notes needs a version')
  const notes = changelogSection(readFileSync('apps/macos/CHANGELOG.md', 'utf8'), version)
  process.stdout.write(`${notes}\n\n${readFileSync('apps/macos/RELEASE_NOTES.md', 'utf8')}`)
}
