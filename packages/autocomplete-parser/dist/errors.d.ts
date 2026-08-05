export declare const MissingSpecError: {
    new (message?: string): {
        name: string;
        message: string;
        stack?: string;
        cause?: unknown;
    };
    isError(error: unknown): error is Error;
};
export declare const WrongDiffVersionedSpecError: {
    new (message?: string): {
        name: string;
        message: string;
        stack?: string;
        cause?: unknown;
    };
    isError(error: unknown): error is Error;
};
export declare const DisabledSpecError: {
    new (message?: string): {
        name: string;
        message: string;
        stack?: string;
        cause?: unknown;
    };
    isError(error: unknown): error is Error;
};
export declare const LoadLocalSpecError: {
    new (message?: string): {
        name: string;
        message: string;
        stack?: string;
        cause?: unknown;
    };
    isError(error: unknown): error is Error;
};
export declare const SpecCDNError: {
    new (message?: string): {
        name: string;
        message: string;
        stack?: string;
        cause?: unknown;
    };
    isError(error: unknown): error is Error;
};
export declare const ParsingHistoryError: {
    new (message?: string): {
        name: string;
        message: string;
        stack?: string;
        cause?: unknown;
    };
    isError(error: unknown): error is Error;
};
export declare const ParseArgumentsError: {
    new (message?: string): {
        name: string;
        message: string;
        stack?: string;
        cause?: unknown;
    };
    isError(error: unknown): error is Error;
};
export declare const UpdateStateError: {
    new (message?: string): {
        name: string;
        message: string;
        stack?: string;
        cause?: unknown;
    };
    isError(error: unknown): error is Error;
};
