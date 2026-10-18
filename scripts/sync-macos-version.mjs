import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** "0.0.1-alpha.2" -> "0.0.1" — Info.plist wants the numeric core. */
export const versionCore = (v) => v.split('-')[0]

export const rewriteInfoPlist = (plist, version) => {
  const core = versionCore(version)
  const re = /(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]*(<\/string>)/
  if (!re.test(plist)) throw new Error('CFBundleShortVersionString not found in Info.plist')
  return plist.replace(re, `$1${core}$2`)
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const version = JSON.parse(readFileSync('apps/macos/package.json', 'utf8')).version
  const path = 'apps/macos/Resources/Info.plist'
  writeFileSync(path, rewriteInfoPlist(readFileSync(path, 'utf8'), version))
  console.log(`Info.plist CFBundleShortVersionString -> ${versionCore(version)}`)
}
