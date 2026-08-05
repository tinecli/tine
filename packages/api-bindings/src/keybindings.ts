import { create } from "@bufbuild/protobuf";
import {
  type Action,
  ActionListSchema,
  type KeybindingPressedNotification,
  NotificationType,
} from "@tine/proto/fig";
import { _subscribe, type NotificationResponse } from "./notifications.js";
import { sendUpdateApplicationPropertiesRequest } from "./requests.js";

export function pressed(
  handler: (
    notification: KeybindingPressedNotification,
  ) => NotificationResponse | undefined,
) {
  return _subscribe(
    { type: NotificationType.NOTIFY_ON_KEYBINDING_PRESSED },
    (notification) => {
      switch (notification?.type?.case) {
        case "keybindingPressedNotification":
          return handler(notification.type.value);
        default:
          break;
      }

      return { unsubscribe: false };
    },
  );
}

export function setInterceptKeystrokes(
  actions: Omit<Action, "$typeName">[],
  intercept: boolean,
  globalIntercept?: boolean,
  currentTerminalSessionId?: string,
) {
  sendUpdateApplicationPropertiesRequest({
    interceptBoundKeystrokes: intercept,
    interceptGlobalKeystrokes: globalIntercept,
    actionList: create(ActionListSchema, { actions }),
    currentTerminalSessionId,
  });
}
