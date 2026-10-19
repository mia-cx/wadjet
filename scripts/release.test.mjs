import assert from 'node:assert/strict'
import test from 'node:test'
import { isReleaseMerge } from './release-merge.mjs'
import { changelogSection } from './release-notes.mjs'
import { rewriteInfoPlist, versionCore } from './sync-macos-version.mjs'

const sha = 'a'.repeat(40)
const repo = 'mia-cx/wadjet'
const merged = {
  merged_at: '2026-10-18T00:00:00Z',
  merge_commit_sha: sha,
  base: { ref: 'main' },
  head: { ref: 'changeset-release/main', repo: { full_name: repo } },
}

test('isReleaseMerge', () => {
  assert.equal(isReleaseMerge([merged], { sha, repository: repo }), true)
  assert.equal(
    isReleaseMerge([{ ...merged, head: { ...merged.head, ref: 'other/main' } }], {
      sha,
      repository: repo,
    }),
    false,
  )
  assert.equal(isReleaseMerge([{ ...merged, merged_at: null }], { sha, repository: repo }), false)
  assert.equal(
    isReleaseMerge([{ ...merged, head: { ...merged.head, repo: { full_name: 'fork/wadjet' } } }], {
      sha,
      repository: repo,
    }),
    false,
  )
  assert.equal(
    isReleaseMerge([{ ...merged, merge_commit_sha: 'b'.repeat(40) }], { sha, repository: repo }),
    false,
  )
  assert.equal(
    isReleaseMerge([{ ...merged, base: { ref: 'develop' } }], { sha, repository: repo }),
    false,
  )
})

test('versionCore strips the prerelease tag', () => {
  assert.equal(versionCore('0.0.1-alpha.2'), '0.0.1')
  assert.equal(versionCore('1.2.3'), '1.2.3')
})

test('rewriteInfoPlist updates only the short version', () => {
  const plist = `<?xml version="1.0"?><plist><dict>
\t<key>CFBundleShortVersionString</key>
\t<string>0.0.1</string>
\t<key>CFBundleVersion</key>
\t<string>42</string>
</dict></plist>`
  const out = rewriteInfoPlist(plist, '0.0.2-beta.1')
  assert.match(out, /<key>CFBundleShortVersionString<\/key>\s*<string>0\.0\.2<\/string>/)
  assert.match(out, /<string>42<\/string>/)
  // same core -> a no-op rewrite, not an error
  assert.equal(rewriteInfoPlist(plist, '0.0.1-alpha.3'), plist)
  assert.throws(() => rewriteInfoPlist('<plist/>', '0.0.1'), /not found/)
})

test('changelogSection returns one version body', () => {
  const md = `# Changelog\n\n## 0.0.1-alpha.2\n\n- new thing\n- another\n\n## 0.0.1-alpha.1\n\n- first alpha\n`
  assert.equal(changelogSection(md, '0.0.1-alpha.2'), '- new thing\n- another')
  assert.equal(changelogSection(md, '0.0.1-alpha.1'), '- first alpha')
  // `## x-alpha.1` must not match inside `## x-alpha.10`
  const md10 = `## 0.0.1-alpha.10\n\n- ten\n\n## 0.0.1-alpha.1\n\n- one\n`
  assert.equal(changelogSection(md10, '0.0.1-alpha.1'), '- one')
  assert.throws(() => changelogSection(md, '9.9.9'), /no "## 9\.9\.9" section/)
})
