import type { SpecLocation } from "@tine/shared/internal";
import { splitPath } from "@tine/shared/utils";
import { WrongDiffVersionedSpecError } from "./errors.js";
import { getVersionFromFullFile, type SpecFileImport } from "./loadHelpers.js";
import { importSpecFromLocation } from "./loadSpec.js";
import { getVersionFromVersionedSpec } from "./specVersions.js";

export const tryResolveSpecToSubcommand = async (
  spec: SpecFileImport,
  location: SpecLocation,
): Promise<Fig.Subcommand> => {
  if (typeof spec.default === "function") {
    // Handle versioned specs, either simple versioned or diff versioned.
    const cliVersion = await getVersionFromFullFile(spec, location.name);
    const subcommandOrDiffVersionInfo = await spec.default(cliVersion);

    if ("versionedSpecPath" in subcommandOrDiffVersionInfo) {
      // Handle diff versioned specs.
      const { versionedSpecPath, version } = subcommandOrDiffVersionInfo;
      const [dirname, basename] = splitPath(versionedSpecPath);
      const { specFile } = await importSpecFromLocation({
        ...location,
        name: dirname.slice(0, -1),
        diffVersionedFile: basename,
      });

      if ("versions" in specFile) {
        const result = getVersionFromVersionedSpec(
          specFile.default,
          specFile.versions,
          version,
        );
        return result.spec;
      }

      throw new WrongDiffVersionedSpecError("Invalid versioned specs file");
    }

    return subcommandOrDiffVersionInfo;
  }

  return spec.default;
};
