import { fs as FileSystem } from "@tine/api-bindings";

// tine: read files through a platform-provided hook when present. Node sets
// globalThis.__tineReadFile = fs.readFile; the Swift app injects it into the
// JSContext. Falls back to the original api-bindings IPC read otherwise.
type ReadFileHook = (path: string) => string | Promise<string>;

export const fread = (path: string): Promise<string> => {
  const hook = (globalThis as { __tineReadFile?: ReadFileHook }).__tineReadFile;
  // Accept a sync (Swift) or async (Node) hook; normalize to a Promise.
  if (hook)
    return Promise.resolve()
      .then(() => hook(path))
      .catch(() => "");
  return FileSystem.read(path).then((out) => out ?? "");
};
