package tunnel

import (
	"strings"
	"testing"

	"github.com/tailscale/tailcat"
)

func TestNodeOwnershipProofCrossPlatformVector(t *testing.T) {
	private, err := parsePrivateKey("privkey:" + strings.Repeat("07", 32))
	if err != nil {
		t.Fatal(err)
	}
	host := &Host{server: &tailcat.Server{Key: private}, public: private.Public().String()}
	proof, err := host.NodeOwnershipProof("10000000-0000-4000-8000-000000000001", "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE")
	if err != nil || proof != "1a9e6c5ea905d95f2e008ef909e577f4f2771d0bb3337dbf17dab8c942e041dd" {
		t.Fatalf("proof=%s err=%v", proof, err)
	}
	for _, challenge := range []string{"bad-key", strings.Repeat("A", 43)} {
		if _, err := host.NodeOwnershipProof("10000000-0000-4000-8000-000000000001", challenge); err == nil {
			t.Fatal("accepted invalid/low-order public key")
		}
	}
	if _, err := host.NodeOwnershipProof("invalid-id", "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE"); err == nil {
		t.Fatal("accepted invalid challenge ID")
	}
}
