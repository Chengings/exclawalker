// `pub fn` — public so it's accessible from main.rs (the binary crate)
// Takes `&str` (borrowed) as input, returns `String` (owned) — caller keeps ownership of input
pub fn transform(input: &str) -> String {
    // Shadows the outer `input` — rebinds the name with a different type (&str slice from trim)
    // `trim_end()` returns a &str slice (no allocation)
    let input = input.trim_end();
    let mut final_str = String::new();

    for char in input.chars() {
        // `&format!(...)` creates a temp String, then borrows it as &str for push_str
        final_str.push_str(&format!("!{char} "));
    }

    // `.to_owned()` converts &str to String (equivalent to .to_string() here)
    final_str.trim_end().to_owned()
}

// `#[cfg(test)]` — conditional compilation; this module is only built during `cargo test`
#[cfg(test)]
mod tests {
    // Imports everything from the parent module (lib.rs root) into this test module
    use super::*;

    #[test]
    fn test_numbers() {
        assert_eq!(transform("123"), "!1 !2 !3");
    }

    #[test]
    fn test_strings() {
        assert_eq!(transform("abc"), "!a !b !c");
    }

    #[test]
    fn test_empty() {
        assert_eq!(transform(""), "");
    }

    #[test]
    fn test_trailing_whitespace_stripped() {
        assert_eq!(transform("abc  "), "!a !b !c");
    }

    #[test]
    fn test_control_chars() {
        // Internal control chars are transformed, trailing newline is stripped
        assert_eq!(transform("a\tb\n"), "!a !	 !b");
    }

    #[test]
    fn test_cjk_characters() {
        assert_eq!(transform("中文"), "!中 !文");
    }

    #[test]
    fn test_multi_byte_chars() {
        assert_eq!(transform("café"), "!c !a !f !é");
        assert_eq!(transform("🎉"), "!🎉");
    }

    #[test]
    fn test_single_char() {
        assert_eq!(transform("x"), "!x");
    }
}
