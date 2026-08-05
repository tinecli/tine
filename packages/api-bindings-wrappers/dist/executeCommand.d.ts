/**
 * NOTE: this is intended to be separate because executeCommand
 * will often be mocked during testing of functions that call it.
 * If it gets bundled in the same file as the functions that call it
 * vitest is not able to mock it (because of esm restrictions).
 */
export declare const cleanOutput: (output: string) => string;
export declare const executeCommandTimeout: (input: Fig.ExecuteCommandInput, timeout?: number) => Promise<Fig.ExecuteCommandOutput>;
