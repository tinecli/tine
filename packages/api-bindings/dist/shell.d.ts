import { type HistoryUpdatedNotification, type ProcessChangedNotification, type ShellPromptReturnedNotification, type TextUpdate } from "@tine/proto/fig";
import { type NotificationResponse } from "./notifications.js";
export declare const processDidChange: {
    subscribe(handler: (notification: ProcessChangedNotification) => NotificationResponse | undefined): Promise<import("./notifications.js").Subscription> | undefined;
};
export declare const promptDidReturn: {
    subscribe(handler: (notification: ShellPromptReturnedNotification) => NotificationResponse | undefined): Promise<import("./notifications.js").Subscription> | undefined;
};
export declare const historyUpdated: {
    subscribe(handler: (notification: HistoryUpdatedNotification) => NotificationResponse | undefined): Promise<import("./notifications.js").Subscription> | undefined;
};
export declare function insert(text: string, request?: Omit<TextUpdate, "insertion" | "$typeName">, terminalSessionId?: string): Promise<void>;
