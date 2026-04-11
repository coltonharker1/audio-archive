package config

import (
	"os"
	"path/filepath"
)

// Config holds application configuration.
type Config struct {
	DataDir    string // root directory for all archive data
	DBPath     string // path to SQLite database
	ModelSize  string // whisper model size (tiny, base, small, medium, large)
	Ffmpeg     string // path to ffmpeg binary
	Ffprobe    string // path to ffprobe binary
	PythonPath string // path to Python binary (venv) — legacy, used by faster-whisper worker
	WorkerPath string // path to Python transcription worker — legacy
	// whisper.cpp migration (see docs/DESIGN.md Optimization roadmap).
	// When WhisperCppBin is non-empty and exists on disk, the pipeline will
	// prefer whisper.cpp over the Python worker. Until then these fields are
	// populated-but-unused so a future session can flip the switch with zero
	// config ceremony.
	WhisperCppBin   string // path to whisper.cpp CLI binary (e.g. /opt/homebrew/bin/whisper-cli)
	WhisperCppModel string // path to GGML model file (e.g. ~/.audio-archive/models/ggml-base.en.bin)
	OllamaModel     string // Ollama model for summarization
}

// Default returns a Config with sensible defaults.
// projectDir is resolved by searching upward for go.mod from the binary's
// working directory; if that fails, it falls back to the current directory.
func Default() Config {
	home, _ := os.UserHomeDir()
	dataDir := filepath.Join(home, ".audio-archive")
	projDir := findProjectRoot()

	return Config{
		DataDir:         dataDir,
		DBPath:          filepath.Join(dataDir, "archive.db"),
		ModelSize:       "base",
		Ffmpeg:          "ffmpeg",
		Ffprobe:         "ffprobe",
		PythonPath:      filepath.Join(projDir, ".venv", "bin", "python"),
		WorkerPath:      filepath.Join(projDir, "worker", "transcribe.py"),
		WhisperCppBin:   "/opt/homebrew/bin/whisper-cli",
		WhisperCppModel: filepath.Join(dataDir, "models", "ggml-base.en.bin"),
		OllamaModel:     "mistral",
	}
}

// findProjectRoot walks up from the working directory looking for go.mod.
func findProjectRoot() string {
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			// Hit filesystem root — fall back to cwd
			cwd, _ := os.Getwd()
			return cwd
		}
		dir = parent
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
