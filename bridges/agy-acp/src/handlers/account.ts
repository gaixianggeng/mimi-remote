import type { GetAccountRateLimitsResponse } from "@mimi/appserver-kit/protocol/codex/v2/GetAccountRateLimitsResponse.ts";
import type { ModelListResponse } from "@mimi/appserver-kit/protocol/codex/v2/ModelListResponse.ts";
import type { RateLimitSnapshot } from "@mimi/appserver-kit/protocol/codex/v2/RateLimitSnapshot.ts";
import type { ModelCatalog } from "../agy/models.ts";

export function createAccountHandlers(models: ModelCatalog, rateLimits: () => Promise<RateLimitSnapshot> | RateLimitSnapshot) {
  return {
    async modelList(): Promise<ModelListResponse> {
      return { data: await models.list(), nextCursor: null };
    },

    async rateLimitsRead(): Promise<GetAccountRateLimitsResponse> {
      return {
        ordinaryUsageAllowed: null,
        rateLimits: await rateLimits(),
        rateLimitsByLimitId: null,
        rateLimitResetCredits: null,
        accountId: null,
        rateLimitUpsell: null,
      };
    },
  };
}
