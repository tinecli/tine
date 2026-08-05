// Separate from execShell so a test can mock executeCommandTimeout without also
// mocking the callers that live beside it.
import { runProcess } from "./host.js";
import { logger } from "./log.js";
import { withTimeout } from "./utils.js";

export const cleanOutput = (output: string) =>
  output
    .replace(/\r\n/g, "\n") // Replace carriage returns with just a normal return
    // biome-ignore lint/suspicious/noControlCharactersInRegex: matches the ANSI show-cursor escape sequence
    .replace(/\x1b\[\?25h/g, "") // removes cursor character if present
    .replace(/^\n+/, "") // strips new lines from start of output
    .replace(/\n+$/, ""); // strips new lines from end of output

export const executeCommandTimeout = async (
  input: Fig.ExecuteCommandInput,
  timeout = 5000,
): Promise<Fig.ExecuteCommandOutput> => {
  const command = [input.command, ...input.args].join(" ");
  try {
    logger.info(`About to run shell command '${command}'`);
    const start = performance.now();
    const result = await withTimeout(
      Math.max(timeout, input.timeout ?? 0),
      runProcess({
        executable: input.command,
        args: input.args,
        environment: input.env,
        workingDirectory: input.cwd,
        timeout: input.timeout,
      }),
    );
    const end = performance.now();
    logger.info(`Result of shell command '${command}'`, {
      result,
      time: end - start,
    });

    const cleanStdout = cleanOutput(result.stdout);
    const cleanStderr = cleanOutput(result.stderr);

    if (result.exitCode !== 0) {
      logger.warn(
        `Command ${command} exited with exit code ${result.exitCode}: ${cleanStderr}`,
      );
    }
    return {
      status: result.exitCode,
      stdout: cleanStdout,
      stderr: cleanStderr,
    };
  } catch (err) {
    logger.error(`Error running shell command '${command}'`, { err });
    throw err;
  }
};
