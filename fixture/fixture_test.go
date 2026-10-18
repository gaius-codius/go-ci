package fixture

import (
	"slices"
	"strings"
	"testing"
)

func TestWords(t *testing.T) {
	tests := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"one", []string{"one"}},
		{"  two\twords \n", []string{"two", "words"}},
	}
	for _, tt := range tests {
		if got := Words(tt.in); !slices.Equal(got, tt.want) {
			t.Errorf("Words(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestCountAtLeast(t *testing.T) {
	if got := CountAtLeast(Words("a abc ab"), 2); got != 2 {
		t.Errorf("CountAtLeast(..., 2) = %d, want 2", got)
	}
}

// FuzzWords gives go.yml's fuzz step a target to run.
func FuzzWords(f *testing.F) {
	f.Add("a b\tc")
	f.Fuzz(func(t *testing.T, s string) {
		words := Words(s)
		if again := Words(strings.Join(words, " ")); !slices.Equal(again, words) {
			t.Errorf("Words is not stable for %q: %q then %q", s, words, again)
		}
	})
}
