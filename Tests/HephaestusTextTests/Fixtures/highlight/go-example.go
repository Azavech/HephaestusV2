//go:build darwin
package main

import "fmt"

// Answer is documented.
func Answer[T any](v T) (int, error) {
	s := `raw\n`
	r := '\''
	fmt.Println(len(s), 0x1F, 1_000, 3.5e-2i, r)
	return 42, nil
}
