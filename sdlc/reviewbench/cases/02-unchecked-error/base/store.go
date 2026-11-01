package store

import "os"

func Load(path string) ([]byte, error) {
	return os.ReadFile(path)
}
