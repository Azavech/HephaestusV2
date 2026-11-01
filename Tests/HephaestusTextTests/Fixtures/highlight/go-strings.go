package strings

var (
	a = "plain"
	b = "escapes \a\b\f\n\r\t\v\\\'\""
	c = "hex \x41 short \x4 unicode \u00e9 short \u00e big \U0001F600 short \U0001F60"
	d = "octal \101 short \18 other \q end"
	e = '\n'
	f = '\''
	g = 'x'
	h = '\x41'
	i = `raw \n "quotes"
second line`
	j = "a\"b"
	k = "trailing backslash \\"
	l = "unterminated
	m = 'unterminated
)
