import { AwsClient } from 'aws4fetch'
import type { BlobStore, ByteRange } from './blob-store.ts'

export interface S3BlobStoreOptions {
  readonly endpoint: string
  readonly bucket: string
  readonly region: string
  readonly accessKeyId: string
  readonly secretAccessKey: string
  readonly forcePathStyle: boolean
}

const encodeKey = (key: string): string => key.split('/').map(encodeURIComponent).join('/')

/** The URL an object lives at, path-style or virtual-hosted, with each key segment encoded. */
export const objectUrl = (options: S3BlobStoreOptions, key: string): string => {
  const endpoint = options.endpoint.replace(/\/$/, '')
  const path = `/${encodeKey(key)}`
  if (options.forcePathStyle) return `${endpoint}/${options.bucket}${path}`
  const url = new URL(endpoint)
  url.host = `${options.bucket}.${url.host}`
  url.pathname = path
  return url.toString()
}

/** Blob store on an S3-compatible endpoint, signed with aws4fetch. No multipart (#51). */
export const s3BlobStore = (options: S3BlobStoreOptions): BlobStore => {
  const aws = new AwsClient({
    service: 's3',
    region: options.region,
    accessKeyId: options.accessKeyId,
    secretAccessKey: options.secretAccessKey,
  })

  const fail = async (verb: string, key: string, res: Response): Promise<never> => {
    const body = (await res.text()).slice(0, 300)
    throw new Error(`S3 ${verb} ${key}: HTTP ${res.status} ${body}`)
  }

  return {
    async put(key, body, length, contentType) {
      const res = await aws.fetch(objectUrl(options, key), {
        method: 'PUT',
        body,
        duplex: 'half',
        headers: {
          'Content-Length': String(length),
          'Content-Type': contentType,
          'X-Amz-Content-Sha256': 'UNSIGNED-PAYLOAD',
        },
      })
      if (!res.ok) await fail('put', key, res)
      await res.body?.cancel()
    },
    async get(key, range?: ByteRange) {
      const headers: Record<string, string> = {}
      if (range) headers.Range = `bytes=${range.offset}-${range.offset + range.length - 1}`
      const res = await aws.fetch(objectUrl(options, key), { headers })
      if (res.status === 404) {
        await res.body?.cancel()
        return undefined
      }
      if (res.status !== 200 && res.status !== 206) await fail('get', key, res)
      if (res.body === null) throw new Error(`S3 get ${key}: empty body on HTTP ${res.status}`)
      return res.body
    },
    async delete(key) {
      const res = await aws.fetch(objectUrl(options, key), { method: 'DELETE' })
      if (!res.ok && res.status !== 404) await fail('delete', key, res)
      await res.body?.cancel()
    },
  }
}
