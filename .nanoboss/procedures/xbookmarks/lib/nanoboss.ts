export type KernelValue = unknown;

export interface TypeDescriptor<T> {
  schema: object;
  validate: (input: unknown) => input is T;
}

export interface RunResult<T = KernelValue> {
  data?: T;
}

export interface ProcedureResult {
  data?: KernelValue;
  display?: string;
  summary?: string;
  pause?: KernelValue;
}

export interface ProcedureApi {
  cwd: string;
  assertNotCancelled(): void;
  agent: {
    run<T>(prompt: string, descriptor: TypeDescriptor<T>, options?: { stream?: boolean }): Promise<RunResult<T>>;
  };
  ui: {
    status(params: { phase?: string; message: string }): void;
  };
}

export interface Procedure {
  name: string;
  description: string;
  inputHint?: string;
  execute(prompt: string, ctx: ProcedureApi): Promise<ProcedureResult | string | void>;
}

export function jsonType<T>(schema: object, validate: (input: unknown) => input is T): TypeDescriptor<T> {
  return { schema, validate };
}

export function expectData<T>(result: RunResult<T>, message = "Missing result data"): T {
  if (result.data === undefined) throw new Error(message);
  return result.data;
}
