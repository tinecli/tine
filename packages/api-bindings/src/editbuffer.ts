import {
  type EditBufferChangedNotification,
  NotificationType,
} from "@tine/proto/fig";
import { _subscribe, type NotificationResponse } from "./notifications.js";

export function subscribe(
  handler: (
    notification: EditBufferChangedNotification,
  ) => NotificationResponse | undefined,
) {
  return _subscribe(
    { type: NotificationType.NOTIFY_ON_EDITBUFFFER_CHANGE },
    (notification) => {
      switch (notification?.type?.case) {
        case "editBufferNotification":
          return handler(notification.type.value);
        default:
          break;
      }

      return { unsubscribe: false };
    },
  );
}
