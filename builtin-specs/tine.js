// tine's own completion spec — a built-in (builtin-specs/), merged into the
// downloaded pack on install. Matches the `tine` shell function in shell/tine.zsh.
export default {
  name: "tine",
  description: "Native macOS terminal autocomplete",
  subcommands: [
    {
      name: "ask",
      description: "Name the installed tool that answers a question",
      args: { name: "question", isVariadic: true },
    },
    { name: "dashboard", description: "Open the dashboard window" },
    { name: "doctor", description: "Check tine is set up correctly" },
    { name: "index", description: "Rebuild the tool index that ask searches" },
    { name: "install", description: "Download the latest completion specs" },
    {
      name: "learn",
      description: "Write a spec for a command from its own --help",
      args: {
        name: "command",
        isCommand: true,
        generators: {
          // Local specs dirs, positionally: sh reads them from "$@", never
          // interpolated into the script body — a dir with shell metacharacters
          // in it can't inject anything.
          script: () => {
            const dirs = Array.isArray(globalThis.__tineLocalSpecsDirs)
              ? globalThis.__tineLocalSpecsDirs.filter(
                  (dir) => typeof dir === "string" && dir,
                )
              : [];
            return {
              command: "/bin/sh",
              args: [
                "-c",
                // biome-ignore lint/suspicious/noTemplateCurlyInString: shell parameter expansion, not a JS template
                'IFS=:; for d in $PATH; do for f in "$d"/*; do [ -x "$f" ] && [ ! -d "$f" ] && printf "P%s\\n" "${f##*/}"; done; done 2>/dev/null; for base in "$@"; do for d in "$base/override" "$base" "$base/extend"; do for f in "$d"/*.js; do [ -f "$f" ] && b=${f##*/} && printf "L%s\\n" "${b%.js}"; done; done; done 2>/dev/null',
                "sh",
                ...dirs,
              ],
            };
          },
          cache: { ttl: 60000, cacheKey: "tine-learn-scan" },
          // --force overwrites, so a command that already has a spec (pack or
          // local) is a valid target again; otherwise offer only what neither
          // knows about yet. The local names (override/<cmd>.js, <cmd>.js, or
          // extend/<cmd>.js under any __tineLocalSpecsDirs entry — the same
          // dirs and files loadSubcommandCached resolves) feed tineHasSpec so
          // there is one predicate, not two lists that can disagree.
          postProcess: (out, tokens) => {
            const pathNames = [];
            const localNames = [];
            for (const line of out.split("\n")) {
              if (line.startsWith("P") && line.length > 1) {
                pathNames.push(line.slice(1));
              } else if (line.startsWith("L") && line.length > 1) {
                localNames.push(line.slice(1));
              }
            }
            if (typeof globalThis.tineSetLocalSpecNames === "function") {
              globalThis.tineSetLocalSpecNames(localNames);
            }
            const names = [...new Set(pathNames)];
            const hasForce =
              tokens.includes("--force") || tokens.includes("-f");
            const hasSpec = globalThis.tineHasSpec;
            if (hasForce || typeof hasSpec !== "function") return names;
            return names.filter((name) => !hasSpec(name));
          },
        },
      },
      options: [
        {
          name: ["--force", "-f"],
          description: "Learn it again, replacing what tine learned before",
        },
      ],
    },
    { name: "restart", description: "Quit and relaunch the app" },
    { name: "update", description: "Update the app to the latest release" },
    { name: "version", description: "Print the running app version" },
    { name: "help", description: "Show usage" },
  ],
  options: [
    { name: ["--version", "-v"], description: "Print the running app version" },
    { name: ["--help", "-h"], description: "Show usage" },
  ],
};
