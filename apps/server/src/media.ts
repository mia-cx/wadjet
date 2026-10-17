import type { Kind } from '@wadjet/protocol'

type FileKind = (typeof Kind)['Type']

/** The media type part of a Content-Type, lowercased, without parameters. */
export const mediaType = (contentType: string): string =>
  (contentType.split(';', 1)[0] ?? '').trim().toLowerCase()

/** Fallback extensions for content types the Mac sends. */
const CONTENT_TYPE_EXTENSIONS: Readonly<Record<string, string>> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/avif': 'avif',
  'image/svg+xml': 'svg',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
  'video/webm': 'webm',
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'audio/x-m4a': 'm4a',
  'audio/wav': 'wav',
  'application/pdf': 'pdf',
  'text/plain': 'txt',
  'text/html': 'html',
  'application/json': 'json',
  'application/zip': 'zip',
}

/** The extension a content type gives when the filename has none. */
export const extensionFor = (contentType: string): string | undefined =>
  CONTENT_TYPE_EXTENSIONS[mediaType(contentType)]

/** `video/*` and `image/gif` are recordings; everything else is a screenshot. */
export const kindFor = (contentType: string): FileKind => {
  const type = mediaType(contentType)
  return type.startsWith('video/') || type === 'image/gif' ? 'recording' : 'screenshot'
}

const INLINE_MEDIA_TYPES = new Set(['application/pdf', 'text/plain'])

/** Types a browser may display inline; HTML and SVG download instead. */
export const isInline = (contentType: string): boolean => {
  const type = mediaType(contentType)
  if (type === 'image/svg+xml') return false
  return (
    type.startsWith('image/') ||
    type.startsWith('video/') ||
    type.startsWith('audio/') ||
    INLINE_MEDIA_TYPES.has(type)
  )
}
