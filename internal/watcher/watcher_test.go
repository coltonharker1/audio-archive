package watcher

import "testing"

func TestIsAudioFile(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{"sermon.wav", true},
		{"sermon.WAV", true},
		{"track.mp3", true},
		{"audio.M4a", true},
		{"flac.flac", true},
		{"recording.aiff", true},
		{"/full/path/to/file.wav", true},
		{"notes.txt", false},
		{"video.mp4", false},
		{"image.jpg", false},
		{"noextension", false},
		{"", false},
	}

	for _, tc := range tests {
		t.Run(tc.path, func(t *testing.T) {
			if got := isAudioFile(tc.path); got != tc.want {
				t.Errorf("isAudioFile(%q) = %v, want %v", tc.path, got, tc.want)
			}
		})
	}
}

func TestIsHiddenOrTemp(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{".DS_Store", true},
		{"._metadata", true},
		{".hidden.wav", true},
		{"/path/to/.hidden", true},
		{"file.tmp", true},
		{"file~", true},
		{"download.part", true},
		{"download.crdownload", true},
		{"sermon.wav", false},
		{"normal-file.mp3", false},
		{"/full/path/real.wav", false},
	}

	for _, tc := range tests {
		t.Run(tc.path, func(t *testing.T) {
			if got := isHiddenOrTemp(tc.path); got != tc.want {
				t.Errorf("isHiddenOrTemp(%q) = %v, want %v", tc.path, got, tc.want)
			}
		})
	}
}
