import { CodewhispererCustomization as Customization } from "@tine/proto/fig";
import { sendCodewhispererListCustomizationRequest } from "./requests.js";

const listCustomizations = async () =>
  (await sendCodewhispererListCustomizationRequest({})).customizations;

export { Customization, listCustomizations };
