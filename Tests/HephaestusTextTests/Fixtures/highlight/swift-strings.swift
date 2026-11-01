let a = "plain"
let b = "escapes \0 \\ \t \n \r \" \' done"
let c = "unicode \u{1F600} \u{41} bad \u{} \u{123456789} \u{12"
let d = "other \q and \#(not) backslashes"
let e = "interpolation \(value) and \(f(x, (y))) and \("nested \(deep)") end"
let f = #"raw \n \#n \#(value) "quoted" \"# end"#
let g = ##"two \#(no) \##(yes) "# still"##
let h = """
    multi-line \(value) "quotes" ""
    continuation \
    blanks \ 	 
    end
    """
let i = #"""
    raw multi-line \(no) \#(yes) """
    """#
let j = "unterminated
let k = "interpolation \(a
    + b)"
let l = ""
let m = "\(x)\(y)"
