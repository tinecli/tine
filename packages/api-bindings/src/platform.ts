import {
  AppBundleType,
  DesktopEnvironment,
  DisplayServerProtocol,
  type GetPlatformInfoResponse,
  Os,
} from "@tine/proto/fig";
import { sendGetPlatformInfoRequest } from "./requests.js";

export { AppBundleType, DesktopEnvironment, DisplayServerProtocol, Os };

export function getPlatformInfo(): Promise<GetPlatformInfoResponse> {
  return sendGetPlatformInfoRequest({});
}
