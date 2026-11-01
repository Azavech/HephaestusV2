//go:build linux && amd64
// +build linux
// +build
//go:generate stringer -type=Kind
//go:embed static/*
//go:noinline
//go:linkname localname runtime.name
//line file.go:10
//export Exported
//extern c_function
//go:Build is a comment
//go: is a comment
//gofmt is a comment
// +builder is a comment
//lines is a comment
package comments // trailing comment
/*line file.go:1:1*/
/* block
   comment */ var x = 1 /* inline */
/**/ /*line*/ /* a /* b */
