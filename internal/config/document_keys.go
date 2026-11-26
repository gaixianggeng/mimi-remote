package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
)

// ValidateSetupDocumentKeys rejects duplicate members and ambiguous spellings
// before a map edit can reorder values decoded to the same config field.
func ValidateSetupDocumentKeys(raw []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	return checkValueKeys(decoder, reflect.TypeFor[Config]())
}
func checkValueKeys(d *json.Decoder, typ reflect.Type) error {
	token, err := d.Token()
	if err != nil {
		return err
	}
	switch token {
	case json.Delim('{'):
		seen := map[string]bool{}
		for d.More() {
			member, err := d.Token()
			if err != nil {
				return err
			}
			key, ok := member.(string)
			if !ok {
				return errors.New("配置字段重复或无效")
			}
			var child reflect.Type
			if typ != nil && typ.Kind() == reflect.Struct {
				for i := 0; i < typ.NumField(); i++ {
					f := typ.Field(i)
					name, _, _ := strings.Cut(f.Tag.Get("json"), ",")
					if strings.EqualFold(key, name) {
						key = name
						child = f.Type
						break
					}
				}
			}
			if seen[key] {
				return errors.New("配置字段有歧义")
			}
			seen[key] = true
			if err = checkValueKeys(d, child); err != nil {
				return err
			}
		}
	case json.Delim('['):
		var element reflect.Type
		if typ != nil && typ.Kind() == reflect.Slice {
			element = typ.Elem()
		}
		for d.More() {
			if err := checkValueKeys(d, element); err != nil {
				return err
			}
		}
	default:
		return nil
	}
	_, err = d.Token()
	return err
}
