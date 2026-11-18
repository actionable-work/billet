use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

const INVENTORY: &str = "{\"items\":[{\"inStock\":true,\"sku\":\"notebook\"}]}\n";

fn main() -> io::Result<()> {
    let listener = TcpListener::bind("0.0.0.0:8080")?;
    for connection in listener.incoming() {
        if let Err(error) = connection.and_then(serve) {
            eprintln!("catalog: {error}");
        }
    }
    Ok(())
}

fn serve(mut stream: TcpStream) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let mut headers = BufReader::new((&stream).take(8192)).lines();
    let request = headers.next().transpose()?.unwrap_or_default();
    for header in headers {
        if header?.is_empty() {
            break;
        }
    }

    let (status, body) = if request.starts_with("GET /items.json ") {
        ("200 OK", INVENTORY)
    } else {
        ("404 Not Found", "{\"error\":\"not found\"}\n")
    };
    write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}
