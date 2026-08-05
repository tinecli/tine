import { create } from "@bufbuild/protobuf";
import { PointSchema, SizeSchema } from "@tine/proto/fig";
import { sendDragWindowRequest, sendPositionWindowRequest, } from "./requests.js";
// Developer Facing API
export async function isValidFrame(frame) {
    return sendPositionWindowRequest({
        size: create(SizeSchema, { width: frame.width, height: frame.height }),
        anchor: create(PointSchema, { x: frame.anchorX, y: 0 }),
        dryrun: true,
    });
}
export async function setFrame(frame) {
    return sendPositionWindowRequest({
        size: create(SizeSchema, { width: frame.width, height: frame.height }),
        anchor: create(PointSchema, {
            x: frame.anchorX,
            y: frame.offsetFromBaseline ?? 0,
        }),
    });
}
export async function dragWindow() {
    return sendDragWindowRequest({});
}
//# sourceMappingURL=position.js.map