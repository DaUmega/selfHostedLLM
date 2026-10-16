// serve.go - web UI + reverse proxy for the Ollama API. Go stdlib only.
// /api/* -> ollama on 127.0.0.1:11434, so one port forward covers UI + API.
// Everything else -> static files from /app.
package main

import (
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
)

func main() {
	dir := "/app"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	target, err := url.Parse("http://127.0.0.1:11434")
	if err != nil {
		fmt.Fprintln(os.Stderr, "[serve] bad target:", err)
		os.Exit(1)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.FlushInterval = -1 // flush every write: /api/chat streams NDJSON

	mux := http.NewServeMux()
	mux.Handle("/api/", proxy)
	mux.Handle("/", http.FileServer(http.Dir(dir)))

	fmt.Println("[serve] serving", dir, "on http://0.0.0.0:8080, proxying /api/ to ollama")
	if err := http.ListenAndServe(":8080", mux); err != nil {
		fmt.Fprintln(os.Stderr, "[serve] error:", err)
		os.Exit(1)
	}
}
