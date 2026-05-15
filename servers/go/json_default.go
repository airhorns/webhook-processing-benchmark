//go:build !goccy

package main

import (
	stdjson "encoding/json"
	"io"
)

type jsonRawMessage = stdjson.RawMessage

func jsonUnmarshal(data []byte, v any) error {
	return stdjson.Unmarshal(data, v)
}

type jsonEncoder interface {
	Encode(v any) error
}

func newJsonEncoder(w io.Writer) jsonEncoder {
	e := stdjson.NewEncoder(w)
	e.SetEscapeHTML(false)
	return e
}

const jsonBackendName = "encoding/json"
