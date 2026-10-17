import { describe, expect, it } from 'vitest'
import type { UploadIndex, UploadRow } from './upload-index.ts'

const row = (id: string, extra: Partial<UploadRow> = {}): UploadRow => ({
  id,
  owner: 'mia',
  blobKey: `files/${id}`,
  storageUploadId: `s3-${id}`,
  filename: `${id}.mp4`,
  kind: 'recording',
  contentType: 'video/mp4',
  size: 2517,
  device: null,
  partBytes: 1024,
  partCount: 3,
  idempotencyKey: null,
  createdAt: new Date('2026-10-16T12:00:00Z'),
  expiresAt: new Date('2026-10-17T12:00:00Z'),
  state: 'open',
  fileId: null,
  completingUntil: null,
  ...extra,
})

/** The behaviour every UploadIndex implementation must satisfy. */
export const uploadIndexContract = (
  name: string,
  index: () => UploadIndex | Promise<UploadIndex>,
) =>
  describe(name, () => {
    it('an idempotent insert returns the earlier row', async () => {
      const uploads = await index()
      const first = row('aaaa01', { idempotencyKey: 'key-1' })
      await uploads.insert(first)
      const again = row('bbbb02', { idempotencyKey: 'key-1' })
      expect(await uploads.insert(again)).toEqual(first)
      await expect(uploads.insert(row('aaaa01'))).rejects.toThrow()
    })

    it('upserts a resent part and lists parts by number', async () => {
      const uploads = await index()
      await uploads.insert(row('aaaa01'))
      await uploads.putPart('aaaa01', { number: 2, size: 1024, etag: 'e2' })
      await uploads.putPart('aaaa01', { number: 1, size: 1024, etag: 'e1' })
      // A resend replaces size and etag.
      await uploads.putPart('aaaa01', { number: 2, size: 512, etag: 'e2b' })
      expect(await uploads.parts('aaaa01')).toEqual([
        { number: 1, size: 1024, etag: 'e1' },
        { number: 2, size: 512, etag: 'e2b' },
      ])
    })

    it('transition succeeds once: a second winner loses', async () => {
      const uploads = await index()
      await uploads.insert(row('aaaa01'))
      expect(await uploads.transition('aaaa01', 'open', 'completed')).toBe(true)
      expect(await uploads.transition('aaaa01', 'open', 'completed')).toBe(false)
      // Setting the fileId afterwards keeps the completed state.
      expect(await uploads.transition('aaaa01', 'completed', 'completed', 'file1')).toBe(true)
      expect((await uploads.get('aaaa01'))?.fileId).toBe('file1')
    })

    it('expired lists overdue open rows; the caller marks them', async () => {
      const uploads = await index()
      const now = new Date('2026-10-18T00:00:00Z')
      await uploads.insert(row('aaaa01')) // expires 2026-10-17
      await uploads.insert(row('bbbb02', { state: 'completed' }))
      await uploads.insert(row('cccc03', { expiresAt: new Date('2026-10-19T00:00:00Z') }))
      const due = await uploads.expired(now, 10)
      expect(due.map((r) => r.id)).toEqual(['aaaa01'])
      // Select-only: marking happens after the caller aborts storage parts.
      expect((await uploads.get('aaaa01'))?.state).toBe('open')
      await uploads.transition('aaaa01', 'open', 'expired')
      expect((await uploads.expired(now, 10)).map((r) => r.id)).toEqual([])
      expect((await uploads.get('bbbb02'))?.state).toBe('completed')
      expect((await uploads.get('cccc03'))?.state).toBe('open')
    })

    it('claimCompletion is exclusive until its lease lapses', async () => {
      const uploads = await index()
      await uploads.insert(row('aaaa01'))
      const t0 = new Date('2026-10-16T12:00:00Z')
      const lease = new Date(t0.getTime() + 5 * 60_000)
      // The first claim wins; while it holds, a second can't take it.
      expect(await uploads.claimCompletion('aaaa01', t0, lease)).toBe(true)
      expect((await uploads.get('aaaa01'))?.state).toBe('completing')
      expect(await uploads.claimCompletion('aaaa01', t0, lease)).toBe(false)
      // After the lease lapses, a stalled completer can be taken over.
      const later = new Date(lease.getTime() + 1)
      expect(await uploads.claimCompletion('aaaa01', later, new Date(later.getTime() + 1))).toBe(
        true,
      )
      // markCompleted releases the lease: the row is completed again.
      await uploads.markCompleted('aaaa01', 'file1')
      const done = await uploads.get('aaaa01')
      expect(done?.state).toBe('completed')
      expect(done?.completingUntil).toBeNull()
      expect(await uploads.claimCompletion('aaaa01', later, lease)).toBe(false)
    })

    it('delete removes the row and its parts', async () => {
      const uploads = await index()
      await uploads.insert(row('aaaa01'))
      await uploads.putPart('aaaa01', { number: 1, size: 1, etag: 'e' })
      await uploads.delete('aaaa01')
      expect(await uploads.get('aaaa01')).toBeUndefined()
      expect(await uploads.parts('aaaa01')).toEqual([])
    })
  })
