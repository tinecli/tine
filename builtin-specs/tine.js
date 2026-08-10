// tine's own completion spec — a built-in (builtin-specs/), merged into the
// downloaded pack on install. Matches the `tine` shell function in shell/tine.zsh.
export default {
  name: "tine",
  description: "Native macOS terminal autocomplete",
  subcommands: [
    { name: "dashboard", description: "Open the dashboard window" },
    { name: "doctor", description: "Check tine is set up correctly" },
    { name: "install", description: "Download the latest completion specs" },
    {
      name: "learn",
      description: "Write a spec for a command from its own --help",
      args: { name: "command", isCommand: true },
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
