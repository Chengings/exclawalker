// Import `transform` from the library crate; crate name comes from Cargo.toml [package] name
use exclawalker::transform;
use std::io;

// io::Result<()> is a type alias for Result<(), io::Error>
fn main() -> io::Result<()> {
    // `let mut` — mutable binding needed because `read_line` appends into the buffer
    let mut input = String::new();

    // `?` propagates the error to the caller instead of panicking (sugar for match/return Err)
    io::stdin().read_line(&mut input)?;

    // `&input` borrows the String as &str via Deref coercion (String implements Deref<Target=str>)
    let result = transform(&input);
    println!("{}", result);

    Ok(())
}
