package main
import "core:strings"

bytes_to_string :: proc(bytes: []byte) -> string {
	return strings.truncate_to_byte(string(bytes), 0)
}


