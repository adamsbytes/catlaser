export interface SuccessBody {
  ok: true;
  data: unknown;
}

export interface ErrorBody {
  ok: false;
  error: {
    code: string;
    message: string;
  };
}

/**
 * Plain `{ name: value }` header map. Chosen over `HeadersInit` so callers
 * cannot smuggle `undefined` values into the response construction path.
 */
export type ResponseHeaders = Readonly<Record<string, string>>;

export const successResponse = (data: unknown, init?: ResponseInit): Response => {
  const body: SuccessBody = { ok: true, data };
  return Response.json(body, init);
};

export const errorResponse = (code: string, message: string, status: number): Response => {
  const body: ErrorBody = { ok: false, error: { code, message } };
  return Response.json(body, { status });
};

/**
 * Build a Response whose body is exactly the caller's JSON — no `{ ok, data }`
 * wrapper. Use this for responses whose body shape is fixed by a third-party
 * contract: AASA (`apple-app-site-association`), Android App Links
 * `assetlinks.json`, etc. Ordinary API endpoints must keep using
 * `successResponse` / `errorResponse`.
 *
 * `Response.json` sets `Content-Type: application/json;charset=UTF-8`
 * automatically; caller-supplied headers are additive.
 */
export const rawJsonResponse = (
  body: unknown,
  headers: ResponseHeaders = {},
  status = 200,
): Response => Response.json(body, { status, headers });

/**
 * Build an HTML response. Used by the Universal Link handler's inert fallback
 * page — a browser that lands on the magic-link URL outside the app must see
 * a static page that does nothing. The `Content-Type` default is HTML +
 * UTF-8; the caller owns every other security-relevant header
 * (`Cache-Control`, `Content-Security-Policy`, `Referrer-Policy`, ...).
 */
export const htmlResponse = (
  html: string,
  headers: ResponseHeaders = {},
  status = 200,
): Response => {
  const withContentType: ResponseHeaders = {
    'Content-Type': 'text/html; charset=utf-8',
    ...headers,
  };
  return new Response(html, { status, headers: withContentType });
};

/**
 * Return a body-less copy of an existing response. Status, status text, and
 * every header are preserved. Used to satisfy the HEAD-method contract:
 * clients receive the metadata that the equivalent GET would produce but no
 * payload. `Bun.serve` would strip the body at the network layer, but that
 * stripping does not happen when handlers are invoked directly (tests,
 * internal routing), so we do it here to keep the contract identical across
 * call sites.
 */
export const emptyBodyResponse = (response: Response): Response =>
  new Response(null, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
