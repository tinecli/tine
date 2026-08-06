import { executeCommandTimeout } from "./exec.js";

export const executeCommand: Fig.ExecuteCommandFunction = (args) =>
  executeCommandTimeout(args);
