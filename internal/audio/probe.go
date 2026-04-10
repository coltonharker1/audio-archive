package audio

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os/exec"
	"strconv"

	"github.com/colton/audio-archive/internal/model"
)

// ffprobeOutput maps the JSON structure returned by ffprobe.
type ffprobeOutput struct {
	Format struct {
		Duration string `json:"duration"`
		BitRate  string `json:"bit_rate"`
	} `json:"format"`
	Streams []struct {
		SampleRate string `json:"sample_rate"`
		Channels   int    `json:"channels"`
		CodecName  string `json:"codec_name"`
	} `json:"streams"`
}

// Probe extracts metadata from an audio file using ffprobe.
func Probe(ctx context.Context, ffprobePath, filePath string) (*model.AudioMeta, error) {
	args := []string{
		"-v", "quiet",
		"-print_format", "json",
		"-show_format",
		"-show_streams",
		filePath,
	}

	cmd := exec.CommandContext(ctx, ffprobePath, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("ffprobe failed: %w\nstderr: %s", err, stderr.String())
	}

	var out ffprobeOutput
	if err := json.Unmarshal(stdout.Bytes(), &out); err != nil {
		return nil, fmt.Errorf("parsing ffprobe output: %w", err)
	}

	meta := &model.AudioMeta{}

	// Parse duration (seconds as float string → milliseconds)
	if dur, err := strconv.ParseFloat(out.Format.Duration, 64); err == nil {
		meta.DurationMs = int64(math.Round(dur * 1000))
	}

	if br, err := strconv.Atoi(out.Format.BitRate); err == nil {
		meta.BitRate = br
	}

	// Use first audio stream for sample rate and channels
	for _, s := range out.Streams {
		if sr, err := strconv.Atoi(s.SampleRate); err == nil {
			meta.SampleRate = sr
			meta.Channels = s.Channels
			meta.Format = s.CodecName
			break
		}
	}

	return meta, nil
}
