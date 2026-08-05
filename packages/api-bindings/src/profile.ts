import { create } from "@bufbuild/protobuf";
import { ProfileSchema } from "@tine/proto/fig";
import {
  sendListAvailableProfilesRequest,
  sendSetProfileRequest,
} from "./requests.js";

export async function listAvailableProfiles() {
  return sendListAvailableProfilesRequest({});
}

export async function setProfile(profileName: string, arn: string) {
  return sendSetProfileRequest({
    profile: create(ProfileSchema, { arn, profileName }),
  });
}
