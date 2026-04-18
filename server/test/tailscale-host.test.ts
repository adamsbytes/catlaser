import { describe, expect, test } from 'bun:test';
import { isPlausibleTailscaleHost } from '~/lib/device-pairing.ts';

/**
 * Unit tests for `isPlausibleTailscaleHost` — the allowlist gate
 * guarding what address the coordination server is willing to hand
 * back to the iOS app as a device endpoint.
 *
 * The app dials `host:port` in plaintext over the Tailscale tunnel.
 * Accepting a non-tailnet host would let a compromised issuance
 * pipeline redirect the app to the public internet, where control
 * frames would be sent and `StreamOffer` payloads (carrying LiveKit
 * URL + subscriber JWT) would be received. Those offers are dialed
 * unconditionally, so the combined attack exfiltrates the victim's
 * stream credentials. This file is the unit-level gate against that
 * class of compromise; the end-to-end surface is covered by
 * `device-pairing.test.ts`.
 */

describe('isPlausibleTailscaleHost — accepted shapes', () => {
  test('accepts CGNAT IPv4 at the low boundary', () => {
    expect(isPlausibleTailscaleHost('100.64.0.1')).toBe(true);
  });

  test('accepts CGNAT IPv4 at the high boundary', () => {
    expect(isPlausibleTailscaleHost('100.127.255.254')).toBe(true);
  });

  test('accepts a typical Tailscale-assigned CGNAT address', () => {
    expect(isPlausibleTailscaleHost('100.64.42.7')).toBe(true);
  });

  test('accepts Tailscale ULA IPv6 in uncompressed form', () => {
    expect(isPlausibleTailscaleHost('fd7a:115c:a1e0:ab12:1234:5678:9abc:def0')).toBe(true);
  });

  test('accepts Tailscale ULA IPv6 in compressed form', () => {
    expect(isPlausibleTailscaleHost('fd7a:115c:a1e0::1')).toBe(true);
  });

  test('accepts bracketed Tailscale ULA IPv6', () => {
    expect(isPlausibleTailscaleHost('[fd7a:115c:a1e0::42]')).toBe(true);
  });

  test('accepts MagicDNS hostname under .ts.net', () => {
    expect(isPlausibleTailscaleHost('catlaser-01.my-tailnet.ts.net')).toBe(true);
  });

  test('accepts MagicDNS hostname under legacy .tailscale.net', () => {
    expect(isPlausibleTailscaleHost('catlaser-01.tailscale.net')).toBe(true);
  });

  test('treats MagicDNS suffix match case-insensitively', () => {
    expect(isPlausibleTailscaleHost('CATLASER-01.MY-TAILNET.TS.NET')).toBe(true);
  });
});

describe('isPlausibleTailscaleHost — rejected shapes', () => {
  test('rejects empty input', () => {
    expect(isPlausibleTailscaleHost('')).toBe(false);
  });

  test('rejects public IPv4 addresses', () => {
    expect(isPlausibleTailscaleHost('8.8.8.8')).toBe(false);
    expect(isPlausibleTailscaleHost('1.1.1.1')).toBe(false);
  });

  test('rejects IPv4 ranges that are not Tailscale CGNAT', () => {
    // RFC 1918 (LAN), loopback, and CGNAT-adjacent addresses. Each is
    // reachable on *some* network, but none of them are Tailscale.
    expect(isPlausibleTailscaleHost('192.168.1.10')).toBe(false);
    expect(isPlausibleTailscaleHost('10.0.0.5')).toBe(false);
    expect(isPlausibleTailscaleHost('172.16.0.1')).toBe(false);
    expect(isPlausibleTailscaleHost('127.0.0.1')).toBe(false);
    expect(isPlausibleTailscaleHost('0.0.0.0')).toBe(false);
  });

  test('rejects IPv4 that is just outside the Tailscale range', () => {
    // The /10 block is `100.64.0.0 .. 100.127.255.255`. The two boundary
    // tests below are the most important: a single bit of drift in the
    // mask constant would let one of them through.
    expect(isPlausibleTailscaleHost('100.63.255.254')).toBe(false);
    expect(isPlausibleTailscaleHost('100.128.0.1')).toBe(false);
  });

  test('rejects IPv4 with malformed octets', () => {
    expect(isPlausibleTailscaleHost('100.64.1.256')).toBe(false);
    expect(isPlausibleTailscaleHost('100.64.1')).toBe(false);
    expect(isPlausibleTailscaleHost('100.64.1.')).toBe(false);
    expect(isPlausibleTailscaleHost('100.64.1.1.1')).toBe(false);
  });

  test('rejects IPv6 outside fd7a:115c:a1e0::/48', () => {
    // `fd7a::1` is the particularly sneaky one — same ULA prefix byte,
    // wrong block. The /48 check must look at all three groups.
    expect(isPlausibleTailscaleHost('fd7a::1')).toBe(false);
    expect(isPlausibleTailscaleHost('fd7a:115c::1')).toBe(false);
    // fd7a:115c:0000::/48 is a sibling block, not Tailscale.
    expect(isPlausibleTailscaleHost('fd7a:115c:a1e1::1')).toBe(false);
    expect(isPlausibleTailscaleHost('2001:db8::1')).toBe(false);
    expect(isPlausibleTailscaleHost('::1')).toBe(false);
  });

  test('rejects IPv6 with zone identifier', () => {
    // Zone ids (`%eth0`, `%1`) are link-local scope markers. A tailnet
    // address never legitimately needs one, and accepting it would open
    // a link-local smuggling path past the allowlist.
    expect(isPlausibleTailscaleHost('fd7a:115c:a1e0::1%eth0')).toBe(false);
    expect(isPlausibleTailscaleHost('fd7a:115c:a1e0::1%1')).toBe(false);
  });

  test('rejects public DNS names', () => {
    expect(isPlausibleTailscaleHost('example.com')).toBe(false);
    expect(isPlausibleTailscaleHost('catlaser-01.example.com')).toBe(false);
    // `*.ts.example.com` is a common phishing shape — the suffix match
    // must be anchored to the actual TLD, not any substring occurrence.
    expect(isPlausibleTailscaleHost('ts.net.example.com')).toBe(false);
  });

  test('rejects bare MagicDNS suffixes', () => {
    expect(isPlausibleTailscaleHost('ts.net')).toBe(false);
    expect(isPlausibleTailscaleHost('.ts.net')).toBe(false);
    expect(isPlausibleTailscaleHost('tailscale.net')).toBe(false);
    expect(isPlausibleTailscaleHost('.tailscale.net')).toBe(false);
  });

  test('rejects MagicDNS with malformed label', () => {
    expect(isPlausibleTailscaleHost('-bad.ts.net')).toBe(false);
    expect(isPlausibleTailscaleHost('bad-.ts.net')).toBe(false);
    expect(isPlausibleTailscaleHost('foo..bar.ts.net')).toBe(false);
  });

  test('rejects URL syntax (scheme, path, port, userinfo)', () => {
    expect(isPlausibleTailscaleHost('https://foo.ts.net')).toBe(false);
    expect(isPlausibleTailscaleHost('foo.ts.net/status')).toBe(false);
    expect(isPlausibleTailscaleHost('user@foo.ts.net')).toBe(false);
    expect(isPlausibleTailscaleHost('foo.ts.net:9820')).toBe(false);
  });

  test('rejects oversized input', () => {
    const huge = `${'a'.repeat(260)}.ts.net`;
    expect(isPlausibleTailscaleHost(huge)).toBe(false);
  });
});
