package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"io"
	"log"
	"net/http"
	"os"
	"runtime"
	"strings"
	"sync"
)

var (
	hmacSecret []byte
	devNull    *os.File
	bufPool    = sync.Pool{
		New: func() any {
			b := make([]byte, 0, 4096)
			return &b
		},
	}
)

const hmacHeader = "X-Shopify-Hmac-Sha256"

type webhookHandler struct{}

func (webhookHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if r.URL.Path != "/webhook" {
		http.NotFound(w, r)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	headerHmac := r.Header.Get(hmacHeader)
	if !verifyHMAC(body, headerHmac) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}

	var payload map[string]jsonRawMessage
	if err := jsonUnmarshal(body, &payload); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	variantsRaw, ok := payload["variants"]
	if !ok {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	var variants []map[string]any
	if err := jsonUnmarshal(variantsRaw, &variants); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	bufPtr := bufPool.Get().(*[]byte)
	buf := bytes.NewBuffer((*bufPtr)[:0])
	for _, v := range variants {
		upcaseInPlace(v)
		buf.Reset()
		enc := newJsonEncoder(buf)
		if err := enc.Encode(v); err != nil {
			continue
		}
		// Encoder adds a trailing newline already.
		if _, err := devNull.Write(buf.Bytes()); err != nil {
			log.Printf("write /dev/null: %v", err)
		}
	}
	*bufPtr = buf.Bytes()
	bufPool.Put(bufPtr)

	w.WriteHeader(http.StatusOK)
}

func upcaseInPlace(v map[string]any) {
	for k, val := range v {
		switch t := val.(type) {
		case string:
			v[k] = strings.ToUpper(t)
		case map[string]any:
			upcaseInPlace(t)
		case []any:
			upcaseList(t)
		}
	}
}

func upcaseList(xs []any) {
	for i, v := range xs {
		switch t := v.(type) {
		case string:
			xs[i] = strings.ToUpper(t)
		case map[string]any:
			upcaseInPlace(t)
		case []any:
			upcaseList(t)
		}
	}
}

func verifyHMAC(body []byte, header string) bool {
	if header == "" {
		return false
	}
	expected, err := base64.StdEncoding.DecodeString(header)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, hmacSecret)
	mac.Write(body)
	got := mac.Sum(nil)
	return hmac.Equal(expected, got)
}

func main() {
	port := envOr("PORT", "8080")
	secretFile := envOr("HMAC_SECRET_FILE", "../../shared/secret.txt")

	sb, err := os.ReadFile(secretFile)
	if err != nil {
		log.Fatalf("read secret: %v", err)
	}
	hmacSecret = bytes.TrimSpace(sb)

	devNull, err = os.OpenFile("/dev/null", os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		log.Fatalf("open /dev/null: %v", err)
	}

	addr := ":" + port
	log.Printf("go server listening on %s (GOMAXPROCS=%d json=%s)", addr, runtime.GOMAXPROCS(0), jsonBackendName)

	srv := &http.Server{
		Addr:    addr,
		Handler: webhookHandler{},
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
