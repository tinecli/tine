import { create } from "@bufbuild/protobuf";
import { DurationSchema, EnvironmentVariableSchema, } from "@tine/proto/fig_common";
import { sendRunProcessRequest } from "./requests.js";
export async function run({ executable, args, environment, workingDirectory, terminalSessionId, timeout, }) {
    const env = environment ?? {};
    return sendRunProcessRequest({
        executable,
        arguments: args,
        env: Object.keys(env).map((key) => create(EnvironmentVariableSchema, { key, value: env[key] })),
        workingDirectory,
        terminalSessionId,
        timeout: timeout
            ? create(DurationSchema, {
                nanos: Math.floor((timeout % 1000) * 1000000000),
                secs: BigInt(Math.floor(timeout / 1000)),
            })
            : undefined,
    });
}
//# sourceMappingURL=process.js.map