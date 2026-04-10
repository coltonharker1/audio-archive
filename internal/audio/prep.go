package audio

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
)

// PrepareAudio runs the FFmpeg audio preparation pipeline:
//   - Convert to 16kHz mono WAV (Whisper's preferred input)
//   - High-pass filter at 80Hz (removes tape rumble/hum)
//   - Normalize audio levels (loudnorm)
//   - Trim leading/trailing silence
func PrepareAudio(ctx context.Context, ffmpegPath, inputPath, outputPath string) error {
	filterChain := "highpass=f=80," +
		"loudnorm=I=-16:TP=-1.5:LRA=11," +
		"silenceremove=start_periods=1:start_silence=0.5:start_threshold=-50dB:" +
		"stop_periods=-1:stop_silence=0.5:stop_threshold=-50dB"

	args := []string{
		"-i", inputPath,
		"-af", filterChain,
		"-ar", "16000",
		"-ac", "1",
		"-y",
		outputPath,
	}

	cmd := exec.CommandContext(ctx, ffmpegPath, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg prep failed: %w\nstderr: %s", err, stderr.String())
	}
	return nil
}
