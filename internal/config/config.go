package config

import (
	"os"
	"path/filepath"
)

// Config holds application configuration.
type Config struct {
	DataDir            string // root directory for all archive data
	DBPath             string // path to SQLite database
	ModelSize          string // whisper model size label — retained for legacy CLI flags; whisper.cpp picks the model via WhisperCppModel
	Ffmpeg             string // path to ffmpeg binary
	Ffprobe            string // path to ffprobe binary
	WhisperCppBin      string // path to whisper.cpp CLI binary (e.g. /opt/homebrew/bin/whisper-cli)
	WhisperCppModel    string // path to GGML speech model file (e.g. ~/.audio-archive/models/ggml-base.en.bin)
	WhisperCppVADModel string // path to Silero VAD model for whisper.cpp; empty disables VAD
	SummarizeEngine    string // "claude" (default) or "ollama"
	ClaudeBin          string // path to the claude CLI binary (for claude engine)
	OllamaModel        string // Ollama model for summarization (for ollama engine)
}

// Default returns a Config with sensible defaults. All paths are absolute
// and rooted in ~/.audio-archive/ so the daemons work regardless of the
// launchd working directory. whisper.cpp binary defaults to the Homebrew
// install path on Apple Silicon.
func Default() Config {
	home, _ := os.UserHomeDir()
	dataDir := filepath.Join(home, ".audio-archive")

	return Config{
		DataDir:            dataDir,
		DBPath:             filepath.Join(dataDir, "archive.db"),
		ModelSize:          "base",
		Ffmpeg:             "ffmpeg",
		Ffprobe:            "ffprobe",
		WhisperCppBin:      "/opt/homebrew/bin/whisper-cli",
		WhisperCppModel:    filepath.Join(dataDir, "models", "ggml-base.en.bin"),
		WhisperCppVADModel: filepath.Join(dataDir, "models", "ggml-silero-v5.1.2.bin"),
		SummarizeEngine:    "claude",
		ClaudeBin:          filepath.Join(home, ".local", "bin", "claude"),
		OllamaModel:        "mistral",
	}
}

// MastersDir returns the path to the masters directory.
func (c Config) MastersDir() string {
	return filepath.Join(c.DataDir, "masters")
}

// ProcessedDir returns the path to the processed audio directory.
func (c Config) ProcessedDir() string {
	return filepath.Join(c.DataDir, "processed")
}

// TranscriptsDir returns the path to the transcripts directory.
func (c Config) TranscriptsDir() string {
	return filepath.Join(c.DataDir, "transcripts")
}

// MetadataDir returns the path to the metadata directory.
func (c Config) MetadataDir() string {
	return filepath.Join(c.DataDir, "metadata")
}

// ModelsDir returns the path to the directory where whisper.cpp GGML model
// files live. Users download ggml-*.bin files here once; the path is static
// so the install workflow can be a single curl.
func (c Config) ModelsDir() string {
	return filepath.Join(c.DataDir, "models")
}

// EnsureDirs creates all required data directories.
func (c Config) EnsureDirs() error {
	dirs := []string{
		c.DataDir,
		c.MastersDir(),
		c.ProcessedDir(),
		c.TranscriptsDir(),
		c.MetadataDir(),
		c.ModelsDir(),
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0755); err != nil {
			return err
		}
	}
	return nil
}
