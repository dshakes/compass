package clamp

import "testing"

func TestClamp(t *testing.T) {
	if got := Clamp(5, 0, 3); got != 3 {
		t.Fatalf("got %d", got)
	}
}
