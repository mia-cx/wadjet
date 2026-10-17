const ID_ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
const ID_LENGTH = 6
const TOKEN_BYTES = 32

const hex = (bytes: ArrayBuffer | Uint8Array): string =>
  [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('')

/** Lowercase hex SHA-256 of `text`, UTF-8 encoded. */
export const sha256Hex = async (text: string): Promise<string> =>
  hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))

/** A 6-character id, uniform over 0-9A-Za-z via rejection sampling. */
export const randomId = (): string => {
  const limit = Math.floor(256 / ID_ALPHABET.length) * ID_ALPHABET.length
  const bytes = new Uint8Array(ID_LENGTH)
  let id = ''
  while (id.length < ID_LENGTH) {
    crypto.getRandomValues(bytes)
    for (const byte of bytes) {
      if (byte < limit) id += ID_ALPHABET[byte % ID_ALPHABET.length]
      if (id.length === ID_LENGTH) break
    }
  }
  return id
}

const base64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/, '')

/** A deletion token: 32 random bytes, base64url without padding. */
export const randomToken = (): string =>
  base64url(crypto.getRandomValues(new Uint8Array(TOKEN_BYTES)))
