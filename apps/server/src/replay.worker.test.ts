import { env } from 'cloudflare:workers'
import { replayContract } from './replay.contract.ts'
import { appFor } from './worker.ts'

replayContract('worker (R2 + D1)', env.FIXTURES, (seams) => appFor(env, seams))
