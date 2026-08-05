import { create } from "@bufbuild/protobuf";
import { NotificationType, TextUpdateSchema, } from "@tine/proto/fig";
import { _subscribe } from "./notifications.js";
import { sendInsertTextRequest } from "./requests.js";
export const processDidChange = {
    subscribe(handler) {
        return _subscribe({ type: NotificationType.NOTIFY_ON_PROCESS_CHANGED }, (notification) => {
            switch (notification?.type?.case) {
                case "processChangeNotification":
                    return handler(notification.type.value);
                default:
                    break;
            }
            return { unsubscribe: false };
        });
    },
};
export const promptDidReturn = {
    subscribe(handler) {
        return _subscribe({ type: NotificationType.NOTIFY_ON_PROMPT }, (notification) => {
            switch (notification?.type?.case) {
                case "shellPromptReturnedNotification":
                    return handler(notification.type.value);
                default:
                    break;
            }
            return { unsubscribe: false };
        });
    },
};
export const historyUpdated = {
    subscribe(handler) {
        return _subscribe({ type: NotificationType.NOTIFY_ON_HISTORY_UPDATED }, (notification) => {
            switch (notification?.type?.case) {
                case "historyUpdatedNotification":
                    return handler(notification.type.value);
                default:
                    break;
            }
            return { unsubscribe: false };
        });
    },
};
export async function insert(text, request, terminalSessionId) {
    if (request) {
        return sendInsertTextRequest({
            terminalSessionId,
            type: {
                case: "update",
                value: create(TextUpdateSchema, { ...request, insertion: text }),
            },
        });
    }
    return sendInsertTextRequest({
        terminalSessionId,
        type: { case: "text", value: text },
    });
}
//# sourceMappingURL=shell.js.map