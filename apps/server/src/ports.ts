/** Injectable seams for the runtime-neutral core. */
export type Clock = () => Date
export type IdGenerator = () => string
export type TokenGenerator = () => string

/** Purges URLs from the CDN edge after a file is deleted. */
export interface CachePurger {
  purge(urls: readonly string[]): Promise<void>
}

export const noopPurger: CachePurger = { purge: () => Promise.resolve() }
