import { AwsClient } from 'aws4fetch'
import { beforeAll } from 'vitest'
import { blobStoreContract } from './blob-store.contract.ts'
import { type S3BlobStoreOptions, s3BlobStore } from './blob-store-s3.ts'

const requireEnv = (name: string): string => {
  const value = process.env[name]
  if (value === undefined || value === '')
    throw new Error(`${name} is required to run the docker tests`)
  return value
}

const options: S3BlobStoreOptions = {
  endpoint: requireEnv('WADJET_TEST_S3_ENDPOINT'),
  bucket: process.env.WADJET_TEST_S3_BUCKET ?? 'wadjet-test',
  region: 'us-east-1',
  accessKeyId: requireEnv('WADJET_TEST_S3_ACCESS_KEY_ID'),
  secretAccessKey: requireEnv('WADJET_TEST_S3_SECRET_ACCESS_KEY'),
  forcePathStyle: true,
}

const aws = new AwsClient({
  service: 's3',
  region: options.region,
  accessKeyId: options.accessKeyId,
  secretAccessKey: options.secretAccessKey,
})

beforeAll(async () => {
  const endpoint = options.endpoint.replace(/\/$/, '')
  const res = await aws.fetch(`${endpoint}/${options.bucket}`, { method: 'PUT' })
  // 409 BucketAlreadyOwnedByYou is fine; a shared store and fixed keys are enough.
  if (!res.ok && res.status !== 409)
    throw new Error(`create bucket: HTTP ${res.status} ${await res.text()}`)
  await res.body?.cancel()
})

blobStoreContract('s3BlobStore (MinIO)', () => s3BlobStore(options))
