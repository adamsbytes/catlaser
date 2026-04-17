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

export const successResponse = (data: unknown, init?: ResponseInit): Response => {
  const body: SuccessBody = { ok: true, data };
  return Response.json(body, init);
};

export const errorResponse = (code: string, message: string, status: number): Response => {
  const body: ErrorBody = { ok: false, error: { code, message } };
  return Response.json(body, { status });
};
