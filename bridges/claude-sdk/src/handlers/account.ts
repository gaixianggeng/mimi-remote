// model/list 与 account/rateLimits/read：iPad 的模型选择、额度显示，以及 agentd 菜单栏的额度。
import type { ModelCatalog } from "../claude/models.ts";
import type { GetAccountRateLimitsResponse } from "../protocol/codex/v2/GetAccountRateLimitsResponse.ts";
import type { ModelListResponse } from "../protocol/codex/v2/ModelListResponse.ts";
import type { RateLimitSnapshot } from "../protocol/codex/v2/RateLimitSnapshot.ts";

/** rateLimits：会话里最近观测到的额度，没有时是「可用性未知」。 */
export function createAccountHandlers(models: ModelCatalog, rateLimits: () => RateLimitSnapshot) {
  return {
    async modelList(): Promise<ModelListResponse> {
      return { data: await models.list(), nextCursor: null };
    },

    rateLimitsRead(): GetAccountRateLimitsResponse {
      return {
        ordinaryUsageAllowed: null,
        rateLimits: rateLimits(),
        rateLimitsByLimitId: null,
        rateLimitResetCredits: null,
        accountId: null,
        rateLimitUpsell: null,
      };
    },
  };
}
