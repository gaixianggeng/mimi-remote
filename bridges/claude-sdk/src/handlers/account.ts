// model/list 与 account/rateLimits/read：iPad 的模型选择、额度显示，以及 agentd 菜单栏的额度。
import type { ModelCatalog } from "../claude/models.ts";
import type { RateLimitReader } from "../claude/usage.ts";
import type { GetAccountRateLimitsResponse } from "../protocol/codex/v2/GetAccountRateLimitsResponse.ts";
import type { ModelListResponse } from "../protocol/codex/v2/ModelListResponse.ts";

export function createAccountHandlers(models: ModelCatalog, rateLimits: RateLimitReader) {
  return {
    async modelList(): Promise<ModelListResponse> {
      return { data: await models.list(), nextCursor: null };
    },

    async rateLimitsRead(): Promise<GetAccountRateLimitsResponse> {
      return {
        ordinaryUsageAllowed: null,
        rateLimits: await rateLimits.read(),
        rateLimitsByLimitId: null,
        rateLimitResetCredits: null,
        accountId: null,
        rateLimitUpsell: null,
      };
    },
  };
}
