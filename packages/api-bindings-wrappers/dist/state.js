var _a;
import { State as DefaultState } from "@tine/api-bindings";
export var States;
(function (States) {
    States["DEVELOPER_API_HOST"] = "developer.apiHost";
    States["DEVELOPER_AE_API_HOST"] = "developer.autocomplete-engine.apiHost";
    States["IS_FIG_PRO"] = "user.account.is-fig-pro";
})(States || (States = {}));
// biome-ignore lint/complexity/noStaticOnlyClass: kept as a class for the private static fields; converting to a module would touch every call site
export class State {
}
_a = State;
State.state = {};
State.subscribers = new Set();
State.current = () => _a.state;
State.subscribe = (subscriber) => {
    _a.subscribers.add(subscriber);
};
State.unsubscribe = (subscriber) => {
    _a.subscribers.delete(subscriber);
};
State.watch = async () => {
    try {
        const state = await DefaultState.current();
        _a.state = state;
        for (const subscriber of _a.subscribers) {
            subscriber.initial?.(state);
        }
    }
    catch {
        // ignore errors
    }
    DefaultState.didChange.subscribe((notification) => {
        const oldState = _a.state;
        const newState = JSON.parse(notification.jsonBlob ?? "{}");
        for (const subscriber of _a.subscribers) {
            subscriber.changes(oldState, newState);
        }
        _a.state = newState;
        return undefined;
    });
};
//# sourceMappingURL=state.js.map