import type { SpecLocation } from "@tine/shared/internal";
import { type SpecFileImport } from "./loadHelpers.js";
export declare const tryResolveSpecToSubcommand: (spec: SpecFileImport, location: SpecLocation) => Promise<Fig.Subcommand>;
