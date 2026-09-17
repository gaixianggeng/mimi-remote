package httpapi

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 与 iOS 共用同一份回包：生产投影变化必须先通过此断言，不能让两端各测各的模型对象。
func TestDeepSeekModelListMatchesSharedIOSContract(t *testing.T) {
	catalog := harnessclient.ModelCatalogResult{
		Groups: []harnessclient.ModelCatalogGroup{
			{ID: "provider-a", Models: []harnessclient.ModelEntry{{
				ID: "harness-model", Name: "Harness Model", Description: "Contract fixture",
				Reasoning: &harnessclient.ModelReasoning{
					Efforts: []harnessclient.ModelReasoningEffort{
						{ID: "low", Name: "Low"}, {ID: "high", Name: "High"},
					},
					DefaultEffort: "high",
				},
			}}},
			{ID: "provider-b", Models: []harnessclient.ModelEntry{{ID: "harness-plain", Name: "Plain Model"}}},
		},
	}
	actualJSON, err := json.Marshal(deepSeekPageResult(deepSeekModelListWire(catalog), 0, false))
	if err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile("../../contracts/mimi-protocol/fixtures/deepseek-model-list.json")
	if err != nil {
		t.Fatal(err)
	}
	var actual, expected any
	if err := json.Unmarshal(actualJSON, &actual); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(fixture, &expected); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("Go model/list 与 iOS 共享回包不同：\nactual: %s\nfixture: %s", actualJSON, fixture)
	}
}
