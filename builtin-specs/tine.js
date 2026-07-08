// tine's own completion spec — shipped in the pack (see scripts/build-specs.sh),
// not a user spec. Matches the `tine` shell function in shell/tine.zsh.
export default {
  name: "tine",
  description: "Native macOS terminal autocomplete",
  subcommands: [
    { name: "dashboard", description: "Open the dashboard window" },
    { name: "doctor", description: "Check tine is set up correctly" },
    { name: "help", description: "Show usage" },
  ],
};
