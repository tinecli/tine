import { type Action, type KeybindingPressedNotification } from "@tine/proto/fig";
import { type NotificationResponse } from "./notifications.js";
export declare function pressed(handler: (notification: KeybindingPressedNotification) => NotificationResponse | undefined): Promise<import("./notifications.js").Subscription> | undefined;
export declare function setInterceptKeystrokes(actions: Omit<Action, "$typeName">[], intercept: boolean, globalIntercept?: boolean, currentTerminalSessionId?: string): void;
