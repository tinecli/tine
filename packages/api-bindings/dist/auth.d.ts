import { type AuthBuilderIdStartDeviceAuthorizationResponse, type AuthCancelPkceAuthorizationResponse, type AuthFinishPkceAuthorizationRequest, type AuthFinishPkceAuthorizationResponse, type AuthStartPkceAuthorizationResponse } from "@tine/proto/fig";
export declare function status(): Promise<{
    authed: boolean;
    authKind: "BuilderId" | "IamIdentityCenter" | undefined;
    startUrl: string | undefined;
    region: string | undefined;
}>;
export declare function startPkceAuthorization({ region, issuerUrl, }?: {
    region?: string;
    issuerUrl?: string;
}): Promise<AuthStartPkceAuthorizationResponse>;
export declare function finishPkceAuthorization({ authRequestId, }: Omit<AuthFinishPkceAuthorizationRequest, "$typeName">): Promise<AuthFinishPkceAuthorizationResponse>;
export declare function cancelPkceAuthorization(): Promise<AuthCancelPkceAuthorizationResponse>;
export declare function builderIdStartDeviceAuthorization({ region, startUrl, }?: {
    region?: string;
    startUrl?: string;
}): Promise<AuthBuilderIdStartDeviceAuthorizationResponse>;
export declare function builderIdPollCreateToken({ authRequestId, expiresIn, interval, }: AuthBuilderIdStartDeviceAuthorizationResponse): Promise<void>;
