package desktopipc

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
)

var ErrSnapshotRequired = errors.New("Desktop IPC full snapshot required")

type StreamChange struct {
	Type              string              `json:"type"`
	Revision          int64               `json:"revision"`
	BaseRevision      int64               `json:"baseRevision"`
	ConversationState map[string]any      `json:"conversationState"`
	Patches           []ConversationPatch `json:"patches"`
}

type ConversationPatch struct {
	Operation string `json:"op"`
	Path      []any  `json:"path"`
	Value     any    `json:"value,omitempty"`
}

type threadState struct {
	revision int64
	state    map[string]any
}

type ThreadStore struct {
	mu      sync.RWMutex
	threads map[string]threadState
}

func NewThreadStore() *ThreadStore {
	return &ThreadStore{threads: make(map[string]threadState)}
}

func (s *ThreadStore) Apply(threadID string, change StreamChange) (map[string]any, error) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return nil, fmt.Errorf("Desktop IPC change is missing conversationId")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	switch strings.ToLower(change.Type) {
	case "snapshot":
		if change.Revision <= 0 || change.ConversationState == nil {
			return nil, fmt.Errorf("Desktop IPC snapshot is incomplete")
		}
		state, err := cloneObject(change.ConversationState)
		if err != nil {
			return nil, err
		}
		s.threads[threadID] = threadState{revision: change.Revision, state: state}
		return cloneObject(state)
	case "patches":
		current, ok := s.threads[threadID]
		if !ok || current.revision != change.BaseRevision || change.Revision != change.BaseRevision+1 {
			delete(s.threads, threadID)
			return nil, ErrSnapshotRequired
		}
		next, err := cloneObject(current.state)
		if err != nil {
			delete(s.threads, threadID)
			return nil, ErrSnapshotRequired
		}
		for _, patch := range change.Patches {
			if err := applyConversationPatch(next, patch); err != nil {
				delete(s.threads, threadID)
				return nil, fmt.Errorf("%w: %v", ErrSnapshotRequired, err)
			}
		}
		s.threads[threadID] = threadState{revision: change.Revision, state: next}
		return cloneObject(next)
	default:
		return nil, fmt.Errorf("unsupported Desktop IPC stream change %q", change.Type)
	}
}

func (s *ThreadStore) Get(threadID string) (map[string]any, int64, bool) {
	s.mu.RLock()
	current, ok := s.threads[strings.TrimSpace(threadID)]
	s.mu.RUnlock()
	if !ok {
		return nil, 0, false
	}
	copy, err := cloneObject(current.state)
	if err != nil {
		return nil, 0, false
	}
	return copy, current.revision, true
}

func (s *ThreadStore) Remove(threadID string) {
	s.mu.Lock()
	delete(s.threads, strings.TrimSpace(threadID))
	s.mu.Unlock()
}

func applyConversationPatch(root map[string]any, patch ConversationPatch) error {
	if len(patch.Path) == 0 {
		return fmt.Errorf("root replacement is not accepted")
	}
	var node any = root
	for _, part := range patch.Path[:len(patch.Path)-1] {
		next, err := childAt(node, part)
		if err != nil {
			return err
		}
		node = next
	}
	last := patch.Path[len(patch.Path)-1]
	switch parent := node.(type) {
	case map[string]any:
		key, ok := last.(string)
		if !ok || key == "" {
			return fmt.Errorf("object patch path is invalid")
		}
		switch strings.ToLower(patch.Operation) {
		case "add", "replace":
			parent[key] = cloneValue(patch.Value)
		case "remove":
			if _, ok := parent[key]; !ok {
				return fmt.Errorf("remove target does not exist")
			}
			delete(parent, key)
		default:
			return fmt.Errorf("unsupported patch operation")
		}
		return nil
	case []any:
		index, ok := patchIndex(last)
		if !ok {
			return fmt.Errorf("array patch index is invalid")
		}
		switch strings.ToLower(patch.Operation) {
		case "replace":
			if index < 0 || index >= len(parent) {
				return fmt.Errorf("replace index is outside the array")
			}
			parent[index] = cloneValue(patch.Value)
		case "remove":
			if index < 0 || index >= len(parent) {
				return fmt.Errorf("remove index is outside the array")
			}
			parent = append(parent[:index], parent[index+1:]...)
			if err := replaceArrayAt(root, patch.Path[:len(patch.Path)-1], parent); err != nil {
				return err
			}
		case "add":
			if index < 0 || index > len(parent) {
				return fmt.Errorf("add index is outside the array")
			}
			parent = append(parent, nil)
			copy(parent[index+1:], parent[index:])
			parent[index] = cloneValue(patch.Value)
			if err := replaceArrayAt(root, patch.Path[:len(patch.Path)-1], parent); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unsupported patch operation")
		}
		return nil
	default:
		return fmt.Errorf("patch parent is not a container")
	}
}

func childAt(parent any, path any) (any, error) {
	switch value := parent.(type) {
	case map[string]any:
		key, ok := path.(string)
		child, found := value[key]
		if !ok || !found {
			return nil, fmt.Errorf("patch object path does not exist")
		}
		return child, nil
	case []any:
		index, ok := patchIndex(path)
		if !ok || index < 0 || index >= len(value) {
			return nil, fmt.Errorf("patch array path does not exist")
		}
		return value[index], nil
	default:
		return nil, fmt.Errorf("patch path crosses a scalar")
	}
}

func replaceArrayAt(root map[string]any, path []any, replacement []any) error {
	if len(path) == 0 {
		return fmt.Errorf("root array replacement is not supported")
	}
	var node any = root
	for _, part := range path[:len(path)-1] {
		next, err := childAt(node, part)
		if err != nil {
			return err
		}
		node = next
	}
	last := path[len(path)-1]
	switch parent := node.(type) {
	case map[string]any:
		key, ok := last.(string)
		if !ok {
			return fmt.Errorf("array parent key is invalid")
		}
		parent[key] = replacement
	case []any:
		index, ok := patchIndex(last)
		if !ok || index < 0 || index >= len(parent) {
			return fmt.Errorf("array parent index is invalid")
		}
		parent[index] = replacement
	default:
		return fmt.Errorf("array parent is not a container")
	}
	return nil
}

func patchIndex(value any) (int, bool) {
	switch number := value.(type) {
	case int:
		return number, true
	case int64:
		return int(number), true
	case float64:
		integer := int(number)
		return integer, number == float64(integer)
	case json.Number:
		integer, err := number.Int64()
		return int(integer), err == nil
	default:
		return 0, false
	}
}

func cloneObject(value map[string]any) (map[string]any, error) {
	payload, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	var copy map[string]any
	if err := json.Unmarshal(payload, &copy); err != nil {
		return nil, err
	}
	return copy, nil
}

func cloneValue(value any) any {
	payload, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	var copy any
	if json.Unmarshal(payload, &copy) != nil {
		return nil
	}
	return copy
}
