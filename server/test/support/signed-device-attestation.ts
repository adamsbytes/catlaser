import { generateKeyPairSync, sign } from 'node:crypto';
import type { KeyObject } from 'node:crypto';
import {
  DEVICE_ID_HEADER,
  DEVICE_SIGNATURE_HEADER,
  DEVICE_TIMESTAMP_HEADER,
  buildDeviceSignedBytes,
} from '~/lib/device-attestation.ts';
import { provisionDevice } from '~/lib/device-provisioning.ts';

/**
 * Test fixture for the Ed25519 device-identity key. Parallels
 * `signed-attestation.ts`'s `TestDeviceKey` but for the
 * device-to-server trust channel (Ed25519) rather than the user
 * Secure-Enclave channel (P-256 ECDSA).
 *
 * Every helper here produces real Ed25519 signatures so the v1
 * device-attestation middleware verifies them end-to-end; no
 * signature-stubbing shortcuts.
 */

export interface TestDeviceIdentity {
  readonly privateKey: KeyObject;
  /** Raw 32-byte Ed25519 public key, ready for base64url encoding. */
  readonly publicKeyRaw: Uint8Array;
  readonly publicKeyBase64Url: string;
}

const toBase64Url = (bytes: Uint8Array): string =>
  Buffer.from(bytes)
    .toString('base64')
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

/**
 * Generate a fresh Ed25519 keypair and surface both halves in
 * useful forms: the `KeyObject` for signing, the raw public-key
 * bytes for on-the-wire encoding, and a pre-computed base64url-no-pad
 * string that matches what the Python brain's identity module emits.
 */
export const createTestDeviceIdentity = (): TestDeviceIdentity => {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const jwk = publicKey.export({ format: 'jwk' });
  const xField = jwk.x;
  if (typeof xField !== 'string') {
    throw new TypeError('generated Ed25519 public key JWK missing "x" field');
  }
  const rawKey = Uint8Array.from(Buffer.from(xField, 'base64url'));
  if (rawKey.length !== 32) {
    throw new Error(`expected 32-byte Ed25519 public key, got ${rawKey.length.toString()}`);
  }
  return {
    privateKey,
    publicKeyRaw: rawKey,
    publicKeyBase64Url: toBase64Url(rawKey),
  };
};

/**
 * Provision a fresh device row under a random Ed25519 key and
 * return the corresponding identity. Every test that mints a
 * pairing code and later claims it must ensure a matching `device`
 * row exists so the pair-exchange handler can emit the
 * `device_public_key` field the iOS client requires.
 */
export const seedProvisionedDevice = async (input: {
  readonly slug: string;
  readonly tailscaleHost: string;
  readonly tailscalePort: number;
  readonly deviceName?: string | null;
}): Promise<TestDeviceIdentity> => {
  const identity = createTestDeviceIdentity();
  await provisionDevice({
    slug: input.slug,
    publicKeyEd25519: identity.publicKeyBase64Url,
    tailscaleHost: input.tailscaleHost,
    tailscalePort: input.tailscalePort,
    deviceName: input.deviceName ?? null,
  });
  return identity;
};

export interface DeviceAttestationHeaderInput {
  readonly identity: TestDeviceIdentity;
  readonly slug: string;
  readonly method: string;
  readonly pathname: string;
  readonly timestamp: number;
}

/**
 * Produce the three-header tuple a real device would send. Tests
 * spread this into `new Request(...)` headers.
 */
export const buildDeviceAttestationHeaders = (
  input: DeviceAttestationHeaderInput,
): Record<string, string> => {
  const signed = buildDeviceSignedBytes(input.method, input.pathname, input.timestamp);
  const sig = sign(null, Buffer.from(signed), input.identity.privateKey);
  return {
    [DEVICE_ID_HEADER]: input.slug,
    [DEVICE_TIMESTAMP_HEADER]: input.timestamp.toString(),
    [DEVICE_SIGNATURE_HEADER]: sig.toString('base64'),
  };
};
