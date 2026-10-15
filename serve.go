// serve.go - tiny static file server for the web UI. Go stdlib only.
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	dir := "/app"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	fmt.Println("[serve] serving", dir, "on http://0.0.0.0:8080")
	if err := http.ListenAndServe(":8080", http.FileServer(http.Dir(dir))); err != nil {
		fmt.Fprintln(os.Stderr, "[serve] error:", err)
		os.Exit(1)
	}
}
