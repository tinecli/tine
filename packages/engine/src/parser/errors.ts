import { createErrorInstance } from "../shared/errors.js";

// LoadSpecErrors
export class MissingSpecError extends Error {
  constructor(
    message: string,
    readonly command: string,
  ) {
    super(message);
    this.name = "AmazonQ.MissingSpecError";
  }
}
export const WrongDiffVersionedSpecError = createErrorInstance(
  "WrongDiffVersionedSpecError",
);
export class LoadLocalSpecError extends Error {
  constructor(
    message: string,
    readonly command = "",
  ) {
    super(message);
    this.name = "AmazonQ.LoadLocalSpecError";
  }
}
export const SpecCDNError = createErrorInstance("SpecCDNError");

// ParsingErrors
export const ParseArgumentsError = createErrorInstance("ParseArgumentsError");
export const UpdateStateError = createErrorInstance("UpdateStateError");
