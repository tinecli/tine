import { create } from "@bufbuild/protobuf";
import { HistoryQueryRequest_ParamSchema, } from "@tine/proto/fig";
import { EmptySchema } from "@tine/proto/fig_common";
import { sendHistoryQueryRequest } from "./requests.js";
function mapParam(param) {
    let type;
    if (param === null) {
        type = {
            case: "null",
            value: create(EmptySchema),
        };
    }
    else if (typeof param === "string") {
        type = { case: "string", value: param };
    }
    else if (typeof param === "number" && Number.isInteger(param)) {
        type = {
            case: "integer",
            value: BigInt(param),
        };
    }
    else if (typeof param === "number") {
        type = {
            case: "float",
            value: param,
        };
    }
    else if (param instanceof Uint8Array) {
        type = {
            case: "blob",
            value: param,
        };
    }
    if (type)
        return create(HistoryQueryRequest_ParamSchema, { type });
    throw new Error("Invalid param type");
}
export async function query(sql, params) {
    const response = await sendHistoryQueryRequest({
        query: sql,
        params: params ? params.map(mapParam) : [],
    });
    return JSON.parse(response.jsonArray);
}
//# sourceMappingURL=history.js.map