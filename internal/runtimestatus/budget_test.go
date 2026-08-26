package runtimestatus

import "testing"

func TestForcedRefreshBudgetsCoverFollowUpGeneration(t *testing.T) {
	if ForcedRefreshHTTPTimeout < 2*ProbeGenerationTimeout {
		t.Fatalf("forced HTTP budget %s does not cover two %s generations", ForcedRefreshHTTPTimeout, ProbeGenerationTimeout)
	}
	if ManualCommandTimeout <= ForcedRefreshHTTPTimeout {
		t.Fatalf("manual command budget %s must include overhead beyond HTTP budget %s", ManualCommandTimeout, ForcedRefreshHTTPTimeout)
	}
}
