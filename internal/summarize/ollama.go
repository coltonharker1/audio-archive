package summarize

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// OllamaClient talks to a local Ollama instance over HTTP.
type OllamaClient struct {
	BaseURL string
	Model   string
	Client  *http.Client
}

// NewOllamaClient creates a client pointed at the default Ollama endpoint.
func NewOllamaClient(model string) *OllamaClient {
	return &OllamaClient{
		BaseURL: "http://localhost:11434",
		Model:   model,
		Client: &http.Client{
			Timeout: 10 * time.Minute,
		},
	}
}

type ollamaRequest struct {
	Model   string          `json:"model"`
	Prompt  string          `json:"prompt"`
	Format  json.RawMessage `json:"format,omitempty"`
	Stream  bool            `json:"stream"`
	Options map[string]any  `json:"options,omitempty"`
}

type ollamaResponse struct {
	Response string `json:"response"`
	Done     bool   `json:"done"`
}

// Generate sends a prompt to Ollama and returns the full response text.
// Set temperature and maxTokens to control generation behavior.
// If jsonSchema is non-nil, Ollama uses it for constrained/structured output.
func (c *OllamaClient) Generate(ctx context.Context, prompt string, opts GenerateOpts) (string, error) {
	temperature := opts.Temperature
	if temperature == 0 {
		temperature = 0.3
	}
	maxTokens := opts.MaxTokens
	if maxTokens == 0 {
		maxTokens = 2048
	}

	req := ollamaRequest{
		Model:  c.Model,
		Prompt: prompt,
		Format: opts.JSONSchema,
		Stream: false,
		Options: map[string]any{
			"temperature": temperature,
			"num_predict": maxTokens,
		},
	}

	body, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("marshaling request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", c.BaseURL+"/api/generate", bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("creating request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.Client.Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("calling Ollama (is it running?): %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("Ollama returned %d: %s", resp.StatusCode, string(respBody))
	}

	var ollamaResp ollamaResponse
	if err := json.NewDecoder(resp.Body).Decode(&ollamaResp); err != nil {
		return "", fmt.Errorf("decoding response: %w", err)
	}

	return ollamaResp.Response, nil
}

// GenerateOpts controls generation parameters for a single Ollama call.
type GenerateOpts struct {
	Temperature float64         // 0.0–1.0, lower = more deterministic
	MaxTokens   int             // max tokens to generate
	JSONSchema  json.RawMessage // if set, Ollama constrains output to this schema
}
