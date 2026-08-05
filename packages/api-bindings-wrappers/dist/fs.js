import { fs as FileSystem } from "@tine/api-bindings";
export const fread = (path) => {
    const hook = globalThis.__tineReadFile;
    // Accept a sync (Swift) or async (Node) hook; normalize to a Promise.
    if (hook)
        return Promise.resolve()
            .then(() => hook(path))
            .catch(() => "");
    return FileSystem.read(path).then((out) => out ?? "");
};
//# sourceMappingURL=fs.js.map