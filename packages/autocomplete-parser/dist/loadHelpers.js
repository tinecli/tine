import logger from "loglevel";
import * as semver from "semver";
import { ensureTrailingSlash, withTimeout, } from "@tine/shared/utils";
import { executeCommand, fread, isInDevMode, } from "@tine/api-bindings-wrappers";
import z from "zod";
import { MOST_USED_SPECS } from "./constants.js";
import { LoadLocalSpecError } from "./errors.js";
const makeCdnUrlFactory = (baseUrl) => (specName, ext = "js") => `${baseUrl}${specName}.${ext}`;
const cdnUrlFactory = makeCdnUrlFactory("https://specs.q.us-east-1.amazonaws.com/");
const stringImportCache = new Map();
// Minimal ESM->CJS rewrite so a user's hand-written spec (`export default …`)
// evaluates via `new Function` in JavaScriptCore. Pack specs are already CJS, so
// these patterns don't match and the source is returned unchanged.
function esmToCjs(str) {
    // Specs are often minified to one line, so anchor on statement boundaries
    // (start / newline / ; / }) rather than line starts.
    const B = "(^|[\\n;}])";
    return str
        // drop imports (unsupported; simple specs don't need them)
        .replace(new RegExp(`${B}\\s*import\\s[^\\n;]*;?`, "g"), "$1")
        // export { a as default, b as c }  ->  module.exports.default = a; …
        .replace(new RegExp(`${B}\\s*export\\s*\\{([^}]*)\\}\\s*;?`, "g"), (_m, lead, inner) => {
        const assigns = inner
            .split(",")
            .map((part) => part.trim())
            .filter(Boolean)
            .map((part) => {
            const [name, alias] = part.split(/\s+as\s+/).map((s) => s.trim());
            return `module.exports[${JSON.stringify(alias || name)}] = ${name};`;
        })
            .join(" ");
        return `${lead}${assigns}`;
    })
        // export default <expr>  ->  module.exports.default = <expr>
        .replace(new RegExp(`${B}\\s*export\\s+default\\s+`, "g"), "$1module.exports.default = ")
        // export const/let/var/function/class/async X  ->  strip `export `
        .replace(new RegExp(`${B}(\\s*)export\\s+(const|let|var|function|class|async)\\b`, "g"), "$1$2$3");
}
export const importString = async (str) => {
    if (stringImportCache.has(str)) {
        return stringImportCache.get(str);
    }
    // tine: pack specs are CJS (esbuild --format=cjs); user's own specs may be
    // ESM (export default …). Normalize ESM to CJS so both eval via `new Function`
    // in JavaScriptCore (no dynamic import / Blob).
    const src = esmToCjs(str);
    const module = { exports: {} };
    new Function("module", "exports", src)(module, module.exports);
    const result = module.exports;
    stringImportCache.set(str, result);
    return result;
};
/*
 * Deprecated: eventually will just use importLocalSpec above
 * Load a spec import("{path}/{name}")
 */
export async function importSpecFromFile(name, path, localLogger = logger) {
    const importFromPath = async (fullPath) => {
        localLogger.info(`Loading spec from ${fullPath}`);
        const contents = await fread(fullPath);
        if (!contents) {
            throw new LoadLocalSpecError(`Failed to read file: ${fullPath}`);
        }
        return contents;
    };
    let result;
    const joinedPath = `${ensureTrailingSlash(path)}${name}`;
    try {
        result = await importFromPath(`${joinedPath}.js`);
    }
    catch (_) {
        result = await importFromPath(`${joinedPath}/index.js`);
    }
    return importString(result);
}
/**
 * Specs can only be loaded from non "secure" contexts, so we can't load from https
 */
export const canLoadSpecProtocol = () => typeof window !== "undefined" ? window.location.protocol !== "https:" : true;
// tine: load specs from the locally-installed spec pack (downloaded by the app
// to __tineSpecsDir), not a CDN. Keeps runtime fully local + offline.
export async function importFromPublicCDN(name) {
    // The pack is the base spec. The user's own specs (~/.tine/specs) are merged
    // on top additively in loadSubcommandCached, so they must NOT shadow here.
    const g = globalThis;
    return importSpecFromFile(name, g.__tineSpecsDir ?? "");
}
async function jsonFromPublicCDN(path) {
    // tine: read JSON (e.g. the spec index) from the local spec pack.
    const dir = globalThis.__tineSpecsDir ?? "";
    const contents = await fread(`${ensureTrailingSlash(dir)}${path}.json`);
    return JSON.parse(contents);
}
// TODO: this is a problem for diff-versioned specs
export async function importFromLocalhost(name, port) {
    return withTimeout(20000, import(
    /* @vite-ignore */
    `http://localhost:${port}/${name}.js`));
}
const cachedCLIVersions = {};
export const getCachedCLIVersion = (key) => cachedCLIVersions[key] ?? null;
export async function getVersionFromFullFile(specData, name) {
    // if the default export is a function it is a versioned spec
    if (typeof specData.default === "function") {
        try {
            const storageKey = `cliVersion-${name}`;
            const version = getCachedCLIVersion(storageKey);
            if (!isInDevMode() && version !== null) {
                return version;
            }
            if ("getVersionCommand" in specData && specData.getVersionCommand) {
                const newVersion = await specData.getVersionCommand(executeCommand);
                cachedCLIVersions[storageKey] = newVersion;
                return newVersion;
            }
            const newVersion = semver.clean((await executeCommand({
                command: name,
                args: ["--version"],
            })).stdout);
            if (newVersion) {
                cachedCLIVersions[storageKey] = newVersion;
                return newVersion;
            }
        }
        catch {
            /**/
        }
    }
    return undefined;
}
// TODO: cache this request using SWR strategy
let publicSpecsRequest;
export function clearSpecIndex() {
    publicSpecsRequest = undefined;
}
const INDEX_ZOD = z.object({
    completions: z.array(z.string()),
    diffVersionedCompletions: z.array(z.string()),
});
const createPublicSpecsRequest = async () => {
    if (publicSpecsRequest === undefined) {
        publicSpecsRequest = jsonFromPublicCDN("index")
            .then(INDEX_ZOD.parse)
            .then((index) => ({
            completions: new Set(index.completions),
            diffVersionedSpecs: new Set(index.diffVersionedCompletions),
        }))
            .catch(() => {
            publicSpecsRequest = undefined;
            return { completions: new Set(), diffVersionedSpecs: new Set() };
        });
    }
    return publicSpecsRequest;
};
export async function publicSpecExists(name) {
    const { completions } = await createPublicSpecsRequest();
    return completions.has(name);
}
export async function isDiffVersionedSpec(name) {
    const { diffVersionedSpecs } = await createPublicSpecsRequest();
    return diffVersionedSpecs.has(name);
}
export async function preloadSpecs() {
    return Promise.all(MOST_USED_SPECS.map(async (name) => {
        // TODO: refactor everything to allow the correct diff-versioned specs to be loaded
        // too, now we are only loading the index
        if (await isDiffVersionedSpec(name)) {
            return importFromPublicCDN(`${name}/index`);
        }
        return importFromPublicCDN(name);
    }).map((promise) => promise.catch((e) => e)));
}
//# sourceMappingURL=loadHelpers.js.map