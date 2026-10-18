import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** The `## <version>` section body from a changesets-generated CHANGELOG. */
export const changelogSection = (changelog, version) => {
  const start = changelog.indexOf(`## ${version}`)
  if (start === -1) throw new Error(`no "## ${version}" section in the changelog`)
  const bodyStart = changelog.indexOf('\n', start) + 1
  const next = changelog.indexOf('\n## ', bodyStart)
  return changelog.slice(bodyStart, next === -1 ? undefined : next + 1).trim()
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const version = process.argv[2]
  if (!version) throw new Error('release-notes needs a version')
  const notes = changelogSection(readFileSync('apps/macos/CHANGELOG.md', 'utf8'), version)
  process.stdout.write(`${notes}\n\n${readFileSync('apps/macos/RELEASE_NOTES.md', 'utf8')}`)
}
