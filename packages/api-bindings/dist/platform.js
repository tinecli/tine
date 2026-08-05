import { AppBundleType, DesktopEnvironment, DisplayServerProtocol, Os, } from "@tine/proto/fig";
import { sendGetPlatformInfoRequest } from "./requests.js";
export { AppBundleType, DesktopEnvironment, DisplayServerProtocol, Os };
export function getPlatformInfo() {
    return sendGetPlatformInfoRequest({});
}
//# sourceMappingURL=platform.js.map