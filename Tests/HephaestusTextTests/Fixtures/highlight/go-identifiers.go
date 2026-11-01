package main

import (
	"fmt"
)

type Celsius float64

type (
	Point struct{ X, Y int }
)

func (p Point) Distance(q Point) float64 {
	var c complex128 = complex(1, 2)
	ch := make(chan int)
	defer close(ch)
	go func() { ch <- len("x") }()
	for i := range iota {
		_ = append([]byte{}, byte(i))
	}
	if true && !false || nil == nil {
		panic(recover())
	} else {
		return 0
	}
	select {
	case v := <-ch:
		fmt.Println(v, cap(ch), max(1, 2), min(3, 4), new(int), real(c), imag(c))
	default:
		print()
		println()
		clear(nil)
		copy(nil, nil)
		delete(nil, 0)
	}
	switch {
	case true:
		fallthrough
	default:
		goto end
	}
end:
	return float64(p.X - q.X)
}

func /* comment */ Generic[T comparable](t T) {}

var _ interface{ M() } = nil
var m map[string]rune
const k, err = uint8(1), error(nil)
var (
	u   uint
	u16 uint16
	u32 uint32
	u64 uint64
	up  uintptr
	u8  uint8
	i8  int8
	i16 int16
	i32 int32
	i64 int64
	f32 float32
	c64 complex64
	ok  bool
	s   string
	a   any
	r   rune
	n   int
)
func main() { for { break; continue } }
var é = Point{}
