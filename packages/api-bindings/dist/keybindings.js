import { create } from "@bufbuild/protobuf";
import { ActionListSchema, NotificationType, } from "@tine/proto/fig";
import { _subscribe } from "./notifications.js";
import { sendUpdateApplicationPropertiesRequest } from "./requests.js";
export function pressed(handler) {
    return _subscribe({ type: NotificationType.NOTIFY_ON_KEYBINDING_PRESSED }, (notification) => {
        switch (notification?.type?.case) {
            case "keybindingPressedNotification":
                return handler(notification.type.value);
            default:
                break;
        }
        return { unsubscribe: false };
    });
}
export function setInterceptKeystrokes(actions, intercept, globalIntercept, currentTerminalSessionId) {
    sendUpdateApplicationPropertiesRequest({
        interceptBoundKeystrokes: intercept,
        interceptGlobalKeystrokes: globalIntercept,
        actionList: create(ActionListSchema, { actions }),
        currentTerminalSessionId,
    });
}
//# sourceMappingURL=keybindings.js.map