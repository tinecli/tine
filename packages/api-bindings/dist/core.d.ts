import { type ClientOriginatedMessage, type ServerOriginatedMessage } from "@tine/proto/fig";
type shouldKeepListening = boolean;
export type APIResponseHandler = (response: ServerOriginatedMessage["submessage"]) => shouldKeepListening | void;
export declare function setHandlerForId(handler: APIResponseHandler, id: string): void;
export declare function sendMessage(submessage: ClientOriginatedMessage["submessage"], handler?: APIResponseHandler): void;
export {};
