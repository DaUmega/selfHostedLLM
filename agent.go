// agent.go - minimal agentic tool loop over Ollama's /api/chat.
// Go stdlib only; builds to a single static binary (no runtime to rot).
//
// The model can read/write/run things inside /work (a shared folder mounted
// from the host). Everything outside /work is unreachable.
//
// Controls (env):
//
//	MODEL       ollama model name              (default: qwen35-9b)
//	MAX_STEPS   max model turns per run        (default: 10)
//	GATE        auto | confirm                 (default: auto)
//	CTX_BUDGET  summarize history past N chars (default: 12000)
//	NUM_CTX     ollama context window          (default: 16384)
//
// Usage:
//
//	agent "your task here"
//	agent --resume "continue where it left off"
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var (
	ollamaURL  = getenv("OLLAMA_URL", "http://localhost:11434")
	model      = getenv("MODEL", "qwen35-9b")
	workDir    = getenv("WORKDIR", "/work")
	maxSteps   = getenvInt("MAX_STEPS", 10)
	gate       = getenv("GATE", "auto") // auto | confirm
	ctxBudget  = getenvInt("CTX_BUDGET", 12000)
	numCtx     = getenvInt("NUM_CTX", 16384)
	httpClient = &http.Client{Timeout: 10 * time.Minute}
	stdin      = bufio.NewReader(os.Stdin)
)

const systemPrompt = `You are a local coding agent running inside /work. That directory is your entire world: read, write and run things only there, using relative paths.
Rules: use tools instead of narrating; be terse. Explore with list_dir/read_file before changing things. When the task is done, answer with a short summary and make no further tool calls.`

func statePath() string { return filepath.Join(workDir, ".agent.json") }

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func getenvInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func strArg(args map[string]any, k string) string {
	if s, ok := args[k].(string); ok {
		return s
	}
	return ""
}

func toInt(v any, def int) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case int:
		return n
	case string:
		if i, err := strconv.Atoi(n); err == nil {
			return i
		}
	}
	return def
}

// shortJSON renders v as JSON, truncated to n chars for log lines.
func shortJSON(v any, n int) string {
	b, _ := json.Marshal(v)
	if len(b) > n {
		return string(b[:n]) + "..."
	}
	return string(b)
}

// ---------- Ollama wire types ----------

type Message struct {
	Role      string     `json:"role"`
	Content   string     `json:"content,omitempty"`
	ToolCalls []ToolCall `json:"tool_calls,omitempty"`
}

type ToolCall struct {
	Function FuncCall `json:"function"`
}

type FuncCall struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments"`
}

type ToolDef struct {
	Type     string  `json:"type"`
	Function FuncDef `json:"function"`
}

type FuncDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
}

type chatRequest struct {
	Model    string         `json:"model"`
	Messages []Message      `json:"messages"`
	Stream   bool           `json:"stream"`
	Tools    []ToolDef      `json:"tools,omitempty"`
	Options  map[string]any `json:"options,omitempty"`
}

type chatResponse struct {
	Message Message `json:"message"`
}

func toolDef(name, desc string, props map[string]any, required []string) ToolDef {
	return ToolDef{Type: "function", Function: FuncDef{
		Name: name, Description: desc,
		Parameters: map[string]any{"type": "object", "properties": props, "required": required},
	}}
}

var tools = []ToolDef{
	toolDef("read_file", "Read a text file under /work. Path is relative to /work.",
		map[string]any{"path": map[string]any{"type": "string"}}, []string{"path"}),
	toolDef("write_file", "Create or overwrite a text file under /work.",
		map[string]any{"path": map[string]any{"type": "string"},
			"content": map[string]any{"type": "string"}}, []string{"path", "content"}),
	toolDef("list_dir", "List directory contents under /work.",
		map[string]any{"path": map[string]any{"type": "string"}}, nil),
	toolDef("exec", "Run a shell command with cwd=/work. Prefer the file tools for reading/writing.",
		map[string]any{"cmd": map[string]any{"type": "string"},
			"timeout": map[string]any{"type": "integer"}}, []string{"cmd"}),
}

// ---------- tool implementations (sandboxed to /work) ----------

func safePath(p string) (string, error) {
	// Clean("/"+p) clamps ".." to /work instead of letting it escape.
	abs, err := filepath.Abs(filepath.Join(workDir, filepath.Clean("/"+p)))
	if err != nil {
		return "", err
	}
	if abs != workDir && !strings.HasPrefix(abs, workDir+string(os.PathSeparator)) {
		return "", fmt.Errorf("path escapes /work: %s", p)
	}
	return abs, nil
}

func toolReadFile(args map[string]any) string {
	p, err := safePath(strArg(args, "path"))
	if err != nil {
		return "error: " + err.Error()
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return "error: " + err.Error()
	}
	return string(b)
}

func toolWriteFile(args map[string]any) string {
	p, err := safePath(strArg(args, "path"))
	if err != nil {
		return "error: " + err.Error()
	}
	if dir := filepath.Dir(p); dir != workDir {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return "error: " + err.Error()
		}
	}
	content := strArg(args, "content")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		return "error: " + err.Error()
	}
	return fmt.Sprintf("wrote %d chars to %s", len(content), strArg(args, "path"))
}

func toolListDir(args map[string]any) string {
	p, err := safePath(strArg(args, "path"))
	if err != nil {
		return "error: " + err.Error()
	}
	entries, err := os.ReadDir(p)
	if err != nil {
		return "error: " + err.Error()
	}
	if len(entries) == 0 {
		return "(empty)"
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return strings.Join(names, "\n")
}

func toolExec(args map[string]any) string {
	cmdStr := strArg(args, "cmd")
	if cmdStr == "" {
		return "error: missing cmd"
	}
	ctx, cancel := context.WithTimeout(context.Background(),
		time.Duration(toInt(args["timeout"], 30))*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", "-c", cmdStr)
	cmd.Dir = workDir
	out, err := cmd.CombinedOutput()
	s := string(out)
	if len(s) > 4000 {
		s = s[len(s)-4000:]
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return fmt.Sprintf("exit=%d\n%s", ee.ExitCode(), s)
		}
		return fmt.Sprintf("error: %v\n%s", err, s)
	}
	return fmt.Sprintf("exit=0\n%s", s)
}

func runTool(name string, args map[string]any) string {
	switch name {
	case "read_file":
		return toolReadFile(args)
	case "write_file":
		return toolWriteFile(args)
	case "list_dir":
		return toolListDir(args)
	case "exec":
		return toolExec(args)
	}
	return "error: unknown tool " + name
}

// ---------- gate ----------

func gated(name string, args map[string]any) string {
	if gate != "confirm" {
		return runTool(name, args)
	}
	fmt.Printf("\n[gate] %s(%s)\nrun? [Y/n/q] ", name, shortJSON(args, 200))
	line, err := stdin.ReadString('\n')
	if err != nil {
		return "denied (no tty for confirmation)"
	}
	switch strings.TrimSpace(strings.ToLower(line)) {
	case "q":
		fmt.Fprintln(os.Stderr, "\n[stop] quit by user")
		os.Exit(0)
	case "n", "no":
		return "denied by user"
	}
	return runTool(name, args)
}

// ---------- ollama ----------

func chat(messages []Message, useTools []ToolDef) (Message, error) {
	body, _ := json.Marshal(chatRequest{
		Model:    model,
		Messages: messages,
		Stream:   false,
		Tools:    useTools,
		Options:  map[string]any{"num_ctx": numCtx},
	})
	req, _ := http.NewRequest("POST", ollamaURL+"/api/chat", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return Message{}, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return Message{}, fmt.Errorf("ollama said %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var cr chatResponse
	if err := json.Unmarshal(b, &cr); err != nil {
		return Message{}, err
	}
	return cr.Message, nil
}

// ---------- context compression ----------

func overBudget(messages []Message) bool {
	n := 0
	for _, m := range messages {
		n += len(m.Content)
	}
	return n > ctxBudget
}

func compress(messages []Message) []Message {
	if len(messages) <= 7 {
		return messages
	}
	head, mid, tail := messages[:2], messages[2:len(messages)-4], messages[len(messages)-4:]
	var sb strings.Builder
	for _, m := range mid {
		c := m.Content
		if len(c) > 1200 {
			c = c[:1200]
		}
		sb.WriteString(m.Role + ": " + c + "\n")
	}
	note, err := chat([]Message{
		{Role: "system", Content: "Compress this agent transcript into a memory note: " +
			"key facts, files touched, decisions, what remains. Under 300 words."},
		{Role: "user", Content: sb.String()},
	}, nil)
	content := ""
	if err == nil {
		content = note.Content
	}
	fmt.Fprintf(os.Stderr, "[ctx] compressed %d messages into memory note\n", len(mid))
	out := append([]Message{}, head...)
	out = append(out, Message{Role: "user", Content: "[memory of earlier steps]\n" + content})
	return append(out, tail...)
}

func save(messages []Message) {
	b, _ := json.Marshal(messages)
	if err := os.WriteFile(statePath(), b, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "[warn] could not save state: %v\n", err)
	}
}

// ---------- main loop ----------

func main() {
	var taskParts []string
	resume := false
	for _, a := range os.Args[1:] {
		if a == "--resume" {
			resume = true
		} else {
			taskParts = append(taskParts, a)
		}
	}

	var messages []Message
	if resume {
		if b, err := os.ReadFile(statePath()); err == nil {
			var loaded []Message
			if json.Unmarshal(b, &loaded) == nil && len(loaded) > 0 {
				messages = loaded
				fmt.Fprintln(os.Stderr, "[resume] loaded previous session")
			}
		}
	}
	if len(messages) == 0 {
		t := strings.TrimSpace(strings.Join(taskParts, " "))
		if t == "" {
			// Only read stdin when it's piped, never block on a tty.
			if fi, err := os.Stdin.Stat(); err == nil && fi.Mode()&os.ModeCharDevice == 0 {
				b, _ := io.ReadAll(os.Stdin)
				t = strings.TrimSpace(string(b))
			}
		}
		if t == "" {
			fmt.Fprintln(os.Stderr, `usage: agent [--resume] "task..."`)
			os.Exit(1)
		}
		messages = []Message{
			{Role: "system", Content: systemPrompt},
			{Role: "user", Content: t},
		}
	} else if len(taskParts) > 0 {
		messages = append(messages, Message{Role: "user", Content: strings.Join(taskParts, " ")})
	}

	for step := 1; step <= maxSteps; step++ {
		if overBudget(messages) {
			messages = compress(messages)
		}
		msg, err := chat(messages, tools)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		if msg.Content != "" {
			fmt.Println(msg.Content)
		}
		if len(msg.ToolCalls) == 0 {
			fmt.Printf("\n[done] after %d step(s)\n", step)
			return
		}
		messages = append(messages, Message{Role: "assistant", Content: msg.Content, ToolCalls: msg.ToolCalls})
		for _, c := range msg.ToolCalls {
			fmt.Fprintf(os.Stderr, "[step %d] %s(%s)\n", step, c.Function.Name, shortJSON(c.Function.Arguments, 160))
			result := gated(c.Function.Name, c.Function.Arguments)
			if len(result) > 4000 {
				result = result[:4000]
			}
			messages = append(messages, Message{Role: "tool", Content: result})
		}
	}
	save(messages)
	fmt.Fprintf(os.Stderr, "[stop] step budget (%d) reached. State saved - resume with: agent --resume\n", maxSteps)
}
