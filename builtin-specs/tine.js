// tine's own completion spec — a built-in (builtin-specs/), merged into the
// downloaded pack on install. Matches the `tine` shell function in shell/tine.zsh.
export default {
  name: "tine",
  description: "Native macOS terminal autocomplete",
  subcommands: [
    { name: "dashboard", description: "Open the dashboard window" },
    { name: "doctor", description: "Check tine is set up correctly" },
    { name: "install", description: "Download the latest completion specs" },
    { name: "restart", description: "Quit and relaunch the app" },
    { name: "help", description: "Show usage" },
  ],
};
