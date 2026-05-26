package audio

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
)

// PrepareAudio runs the FFmpeg audio preparation pipeline:
//
//  1. Downsample to 16 kHz mono FIRST (via aformat at the start of the filter
//     chain). This is the Whisper-preferred format AND it drops the data rate
//     by ~6x for typical 48 kHz 24-bit stereo tape digitizations, making
//     every subsequent filter proportionally faster.
//  2. Notch filters at 60/120/180/240 Hz — removes electrical hum and
//     harmonics common on old tape recordings. Narrow Q=5 bandreject filters
//     are surgical enough to leave speech fundamentals intact.
//  3. High-pass filter at 80 Hz — removes tape rumble below the hum range.
//  4. FFT denoiser (afftdn nf=-25) — removes stationary noise like tape hiss.
//     The noise floor of -25 dB is conservative enough to avoid speech
//     artifacts while still cleaning up the high-frequency hiss that confuses
//     Whisper's attention mechanism.
//  5. Compressor — evens out the large dynamic range swings common on old
//     tape recordings so Whisper gets consistent input levels across quiet
//     and loud passages.
//  6. Loudnorm (single-pass, EBU R128 target -16 LUFS) — final level
//     normalization.
//
// Notes on what we intentionally DO NOT do:
//
//   - No silenceremove filter. Whisper with vad_filter=True already skips
//     non-speech regions; doing it at the ffmpeg stage is redundant work.
//     Silenceremove is also expensive on long files because it scans the
//     full audio.
//   - No two-pass loudnorm. Single-pass is slightly less precise but
//     imperceptibly so for sermon/voicemail content, and two-pass doubles
//     the runtime.
//
// -threads 0 tells ffmpeg to use all available CPU cores for the filter
// chain, which is a meaningful win on Apple Silicon with 10+ cores.
func PrepareAudio(ctx context.Context, ffmpegPath, inputPath, outputPath string) error {
	// The aformat filter triggers automatic insertion of aresample and
	// channel-mixdown filters when the input doesn't match the requested
	// rate/layout, so this works for both stereo and mono input at any rate.
	//
	// Order matters: we put aformat first so the downstream filters see
	// the smaller data stream.
	filterChain := "aformat=sample_rates=16000:channel_layouts=mono," +
		"bandreject=f=60:width_type=q:w=5," +
		"bandreject=f=120:width_type=q:w=5," +
		"bandreject=f=180:width_type=q:w=5," +
		"bandreject=f=240:width_type=q:w=5," +
		"highpass=f=80," +
		"afftdn=nf=-25," +
		"acompressor=threshold=-20dB:ratio=3:attack=5:release=50:makeup=2," +
		"loudnorm=I=-16:TP=-1.5:LRA=11"

	args := []string{
		"-i", inputPath,
		"-af", filterChain,
		"-threads", "0",
		// Defensive: even though aformat already does this, explicit output
		// format ensures the encoder gets the expected input.
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
