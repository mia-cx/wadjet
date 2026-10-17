import { describe, expect, it } from 'vitest'
import type { FileIndex, FileRow } from './file-index.ts'

const row = (
  id: string,
  createdAt: string,
  owner = 'mia',
  extra: Partial<FileRow> = {},
): FileRow => ({
  id,
  owner,
  filename: `${id}.png`,
  extension: 'png',
  kind: 'screenshot',
  contentType: 'image/png',
  size: 1,
  device: null,
  createdAt: new Date(createdAt),
  blobKey: `files/${id}`,
  deleteTokenHash: 'x'.repeat(64),
  idempotencyKey: null,
  deletedAt: null,
  thumbnailVersion: 0,
  thumbnailBlobKey: null,
  thumbnailContentType: null,
  thumbnailSize: null,
  ...extra,
})

const T1 = '2026-10-16T12:00:00Z'
const T2 = '2026-10-16T12:01:00Z'
const T3 = '2026-10-16T12:02:00Z'

/** The behaviour every FileIndex implementation must satisfy. */
export const fileIndexContract = (name: string, index: () => FileIndex | Promise<FileIndex>) =>
  describe(name, () => {
    it('pages newest first by (createdAt desc, id desc) with cursor ties', async () => {
      const files = await index()
      await files.insert(row('aaaa01', T1))
      await files.insert(row('aaaaaa', T2))
      await files.insert(row('bbbbbb', T2))
      await files.insert(row('zzzz03', T3))

      const page1 = await files.list('mia', 2)
      expect(page1.map((r) => r.id)).toEqual(['zzzz03', 'bbbbbb'])

      const page2 = await files.list('mia', 2, { createdAt: new Date(T2), id: 'bbbbbb' })
      expect(page2.map((r) => r.id)).toEqual(['aaaaaa', 'aaaa01'])

      const page3 = await files.list('mia', 2, { createdAt: new Date(T1), id: 'aaaa01' })
      expect(page3).toEqual([])
    })

    it('orders ids bytewise at a createdAt tie, in sort and in cursor', async () => {
      const files = await index()
      await files.insert(row('Zzzzz1', T1))
      await files.insert(row('aaaaa1', T1))
      expect((await files.list('mia', 10)).map((r) => r.id)).toEqual(['aaaaa1', 'Zzzzz1'])
      const page = await files.list('mia', 10, { createdAt: new Date(T1), id: 'aaaaa1' })
      expect(page.map((r) => r.id)).toEqual(['Zzzzz1'])
    })

    it('only ever lists the owner’s files', async () => {
      const files = await index()
      await files.insert(row('aaaa01', T1, 'mia'))
      await files.insert(row('bbbb02', T3, 'other'))
      expect((await files.list('mia', 10)).map((r) => r.id)).toEqual(['aaaa01'])
      expect((await files.list('other', 10)).map((r) => r.id)).toEqual(['bbbb02'])
    })

    it('scopes idempotency keys per owner', async () => {
      const files = await index()
      await files.insert(row('aaaa01', T1, 'mia', { idempotencyKey: 'key-1' }))
      await files.insert(row('bbbb02', T1, 'other', { idempotencyKey: 'key-1' }))
      expect((await files.findByIdempotencyKey('mia', 'key-1'))?.id).toBe('aaaa01')
      expect((await files.findByIdempotencyKey('other', 'key-1'))?.id).toBe('bbbb02')
      expect(await files.findByIdempotencyKey('mia', 'other-key')).toBeUndefined()
    })

    it('resolves an idempotency-key conflict to the first row and rejects a taken id', async () => {
      const files = await index()
      const first = row('aaaa01', T1, 'mia', { idempotencyKey: 'key-1' })
      await files.insert(first)

      const second = row('bbbb02', T2, 'mia', { idempotencyKey: 'key-1' })
      expect(await files.insert(second)).toEqual(first)
      expect((await files.list('mia', 10)).map((r) => r.id)).toEqual(['aaaa01'])

      const taken = row('aaaa01', T3, 'mia')
      await expect(files.insert(taken)).rejects.toThrow()
    })

    it('gets and deletes by id', async () => {
      const files = await index()
      await files.insert(row('aaaa01', T1))
      expect((await files.get('aaaa01'))?.id).toBe('aaaa01')
      await files.delete('aaaa01')
      expect(await files.get('aaaa01')).toBeUndefined()
    })

    it('markDeleted tombstones the row and releases its idempotency key', async () => {
      const files = await index()
      const inserted = row('aaaa01', T1, 'mia', { idempotencyKey: 'key-1' })
      await files.insert(inserted)

      const at = new Date(T2)
      await files.markDeleted('aaaa01', at)

      expect(await files.list('mia', 10)).toEqual([])
      expect(await files.get('aaaa01')).toEqual({
        ...inserted,
        deletedAt: at,
        idempotencyKey: null,
      })
      expect(await files.findByIdempotencyKey('mia', 'key-1')).toBeUndefined()

      // The released key belongs to a new file now; the tombstone's id stays taken.
      const retry = row('bbbb02', T3, 'mia', { idempotencyKey: 'key-1' })
      expect(await files.insert(retry)).toEqual(retry)
      await expect(files.insert(row('aaaa01', T3))).rejects.toThrow()
    })

    it('setThumbnail claims only the version it expected', async () => {
      const files = await index()
      await files.insert(row('aaaa01', T1))
      expect(
        await files.setThumbnail('aaaa01', 0, {
          version: 1,
          blobKey: 'thumbnails/aaaa01-v1',
          contentType: 'image/webp',
          size: 122,
        }),
      ).toBe(true)
      expect(await files.get('aaaa01')).toMatchObject({
        thumbnailVersion: 1,
        thumbnailBlobKey: 'thumbnails/aaaa01-v1',
        thumbnailContentType: 'image/webp',
        thumbnailSize: 122,
      })
      // A claim based on a stale read loses; the row is untouched.
      expect(
        await files.setThumbnail('aaaa01', 0, {
          version: 1,
          blobKey: 'thumbnails/aaaa01-stale',
          contentType: 'image/png',
          size: 1,
        }),
      ).toBe(false)
      expect((await files.get('aaaa01'))?.thumbnailVersion).toBe(1)
    })
  })
