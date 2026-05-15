//go:build goccy

package main

import (
	"io"

	gocjson "github.com/goccy/go-json"
)

type jsonRawMessage = gocjson.RawMessage

func jsonUnmarshal(data []byte, v any) error {
	return gocjson.Unmarshal(data, v)
}

type jsonEncoder interface {
	Encode(v any) error
}

func newJsonEncoder(w io.Writer) jsonEncoder {
	e := gocjson.NewEncoder(w)
	e.SetEscapeHTML(false)
	return e
}

const jsonBackendName = "goccy/go-json"
