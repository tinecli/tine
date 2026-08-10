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
          script: [
            "/bin/sh",
            "-c",
            // biome-ignore lint/suspicious/noTemplateCurlyInString: shell parameter expansion, not a JS template
            'IFS=:; for d in $PATH; do for f in "$d"/*; do [ -x "$f" ] && [ ! -d "$f" ] && printf "%s\\n" "${f##*/}"; done; done 2>/dev/null',
          ],
          cache: { ttl: 60000 },
          // --force overwrites, so a command that already has a spec is a valid
          // target again; otherwise offer only what tine doesn't know yet.
          postProcess: (out, tokens) => {
            const names = [...new Set(out.split("\n").filter(Boolean))];
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
