package transcribe

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// canonical whisper.cpp --output-json payload, trimmed to the fields this
// package consumes. Shape cross-referenced with whisper.cpp's cli.cpp writer.
const sampleWhisperCppJSON = `{
  "systeminfo": "AVX2 = 0",
  "model": {"type": "base", "multilingual": true},
  "params": {"model": "ggml-base.en.bin", "language": "en", "translate": false},
  "result": {"language": "en"},
  "transcription": [
    {"timestamps": {"from": "00:00:00,000", "to": "00:00:02,500"},
     "offsets":    {"from": 0,    "to": 2500},
     "text": " And it came to pass in those days"},
    {"timestamps": {"from": "00:00:02,500", "to": "00:00:05,100"},
     "offsets":    {"from": 2500, "to": 5100},
     "text": " that there went out a decree from Caesar Augustus."},
    {"timestamps": {"from": "00:00:05,100", "to": "00:00:05,100"},
     "offsets":    {"from": 5100, "to": 5100},
     "text": "   "}
  ]
}`

func TestParseWhisperCppJSON_HappyPath(t *testing.T) {
	got, err := parseWhisperCppJSON([]byte(sampleWhisperCppJSON))
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}

	if got.Language != "en" {
		t.Errorf("Language = %q, want %q", got.Language, "en")
	}
	if len(got.Segments) != 2 {
		t.Errorf("len(Segments) = %d, want 2 (empty-text segment should be dropped)", len(got.Segments))
	}
	if got.Duration != 5.1 {
		t.Errorf("Duration = %v, want 5.1", got.Duration)
	}
	if got.Segments[0].Start != 0 || got.Segments[0].End != 2.5 {
		t.Errorf("Segments[0] timing = (%v, %v), want (0, 2.5)", got.Segments[0].Start, got.Segments[0].End)
	}
	expectedFull := "And it came to pass in those days that there went out a decree from Caesar Augustus."
	if got.FullText != expectedFull {
		t.Errorf("FullText = %q\nwant     %q", got.FullText, expectedFull)
	}
}

func TestParseWhisperCppJSON_EmptyTranscription(t *testing.T) {
	// The canary for VAD parity on non-speech audio: whisper.cpp produces
	// an empty transcription array when VAD skips the whole clip.
	raw := `{"result":{"language":"en"},"transcription":[]}`
	got, err := parseWhisperCppJSON([]byte(raw))
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if got.FullText != "" {
		t.Errorf("expected empty FullText, got %q", got.FullText)
	}
	if len(got.Segments) != 0 {
		t.Errorf("expected 0 segments, got %d", len(got.Segments))
	}
	if got.Duration != 0 {
		t.Errorf("expected 0 duration, got %v", got.Duration)
	}
}

func TestParseWhisperCppJSON_Malformed(t *testing.T) {
	if _, err := parseWhisperCppJSON([]byte("not json")); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// TestRunWhisperCpp_FakeBinary exercises the end-to-end RunWhisperCpp path
// using a fake shell script standing in for whisper-cli. The fake accepts
// the expected CLI args, writes canned JSON to the --output-file location,
// and exits 0. This lets us verify:
//   - Arg construction doesn't regress
//   - We read from the right output path (--output-file + .json)
//   - Parsing wires into the real Result type
//
// The actual whisper.cpp binary is never invoked, so this test passes on
// any dev machine without brew install whisper-cpp.
func TestRunWhisperCpp_FakeBinary(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix-only")
	}

	dir := t.TempDir()

	// Create fake audio, speech model, and VAD model files so the Stat
	// checks inside RunWhisperCpp pass.
	audioPath := filepath.Join(dir, "sample.wav")
	if err := os.WriteFile(audioPath, []byte("fake wav"), 0o644); err != nil {
		t.Fatalf("write audio: %v", err)
	}
	modelPath := filepath.Join(dir, "ggml-base.en.bin")
	if err := os.WriteFile(modelPath, []byte("fake model"), 0o644); err != nil {
		t.Fatalf("write model: %v", err)
	}
	vadPath := filepath.Join(dir, "ggml-silero.bin")
	if err := os.WriteFile(vadPath, []byte("fake vad"), 0o644); err != nil {
		t.Fatalf("write vad model: %v", err)
	}

	// Fake whisper-cli: parses --output-file, asserts --vad/--vad-model
	// pair consistency (either both or neither), writes canned JSON to
	// --output-file + ".json", exits 0.
	fakeBin := filepath.Join(dir, "fake-whisper-cli.sh")
	script := fmt.Sprintf(`#!/bin/sh
OUT=""
VAD=0
VAD_MODEL=""
while [ $# -gt 0 ]; do
	case "$1" in
		--output-file) OUT="$2"; shift 2 ;;
		--vad) VAD=1; shift ;;
		--vad-model) VAD_MODEL="$2"; shift 2 ;;
		*) shift ;;
	esac
done
if [ -z "$OUT" ]; then
	echo "fake whisper-cli: --output-file not passed" >&2
	exit 2
fi
if [ "$VAD" = "1" ] && [ -z "$VAD_MODEL" ]; then
	# Mirror real whisper.cpp behaviour: aborts without a VAD model.
	echo "fake whisper-cli: --vad without --vad-model" >&2
	exit 3
fi
cat > "${OUT}.json" <<'JSON'
%s
JSON
`, sampleWhisperCppJSON)
	if err := os.WriteFile(fakeBin, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake whisper-cli: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Happy path: VAD model provided.
	got, err := RunWhisperCpp(ctx, fakeBin, modelPath, vadPath, audioPath)
	if err != nil {
		t.Fatalf("RunWhisperCpp with VAD: %v", err)
	}
	if len(got.Segments) != 2 {
		t.Fatalf("expected 2 segments, got %d", len(got.Segments))
	}
	if got.Language != "en" {
		t.Errorf("language = %q, want en", got.Language)
	}

	// VAD-disabled path: empty VAD model path is legal and must not
	// append --vad flags to the child invocation (otherwise the fake
	// aborts with exit 3).
	got2, err := RunWhisperCpp(ctx, fakeBin, modelPath, "", audioPath)
	if err != nil {
		t.Fatalf("RunWhisperCpp without VAD: %v", err)
	}
	if len(got2.Segments) != 2 {
		t.Fatalf("expected 2 segments (vad off), got %d", len(got2.Segments))
	}
}

func TestRunWhisperCpp_MissingBinary(t *testing.T) {
	dir := t.TempDir()
	audio := filepath.Join(dir, "a.wav")
	model := filepath.Join(dir, "m.bin")
	_ = os.WriteFile(audio, []byte("x"), 0o644)
	_ = os.WriteFile(model, []byte("x"), 0o644)

	_, err := RunWhisperCpp(context.Background(), filepath.Join(dir, "nope"), model, "", audio)
	if err == nil {
		t.Fatal("expected missing-binary error, got nil")
	}
}

func TestRunWhisperCpp_MissingVADModel(t *testing.T) {
	dir := t.TempDir()
	audio := filepath.Join(dir, "a.wav")
	model := filepath.Join(dir, "m.bin")
	_ = os.WriteFile(audio, []byte("x"), 0o644)
	_ = os.WriteFile(model, []byte("x"), 0o644)
	// Bin must exist so we get past the binary Stat check.
	bin := filepath.Join(dir, "fake")
	_ = os.WriteFile(bin, []byte("#!/bin/sh\nexit 0\n"), 0o755)

	_, err := RunWhisperCpp(context.Background(), bin, model, filepath.Join(dir, "nope-vad"), audio)
	if err == nil {
		t.Fatal("expected error when VAD model path is set but missing")
	}
}
