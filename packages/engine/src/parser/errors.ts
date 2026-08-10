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
export const LoadLocalSpecError = createErrorInstance("LoadLocalSpecError");
export const SpecCDNError = createErrorInstance("SpecCDNError");

// ParsingErrors
export const ParseArgumentsError = createErrorInstance("ParseArgumentsError");
export const UpdateStateError = createErrorInstance("UpdateStateError");
