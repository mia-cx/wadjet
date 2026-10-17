import { describe, expect, it } from 'vitest'
import { objectUrl, type S3BlobStoreOptions } from './blob-store-s3.ts'

const options = (overrides: Partial<S3BlobStoreOptions> = {}): S3BlobStoreOptions => ({
  endpoint: 'https://s3.example.com',
  bucket: 'wadjet',
  region: 'auto',
  accessKeyId: 'id',
  secretAccessKey: 'secret',
  forcePathStyle: false,
  ...overrides,
})

describe('objectUrl', () => {
  it('builds a path-style URL', () => {
    expect(objectUrl(options({ forcePathStyle: true }), 'files/aB3xK9')).toBe(
      'https://s3.example.com/wadjet/files/aB3xK9',
    )
  })

  it('builds a virtual-hosted URL', () => {
    expect(objectUrl(options(), 'files/aB3xK9')).toBe('https://wadjet.s3.example.com/files/aB3xK9')
  })

  it('keeps an endpoint port', () => {
    const url = objectUrl(options({ endpoint: 'http://minio.local:9000' }), 'k')
    expect(url).toBe('http://wadjet.minio.local:9000/k')
  })

  it('strips a trailing slash on the endpoint', () => {
    expect(
      objectUrl(options({ endpoint: 'https://s3.example.com/', forcePathStyle: true }), 'k'),
    ).toBe('https://s3.example.com/wadjet/k')
  })

  it('encodes each key segment, keeping slashes', () => {
    expect(objectUrl(options({ forcePathStyle: true }), 'files/a b#c?.png')).toBe(
      'https://s3.example.com/wadjet/files/a%20b%23c%3F.png',
    )
  })
})
