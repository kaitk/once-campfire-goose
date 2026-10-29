import std;
import http from "github.com/kaitk/goose-http@c58a340abe8ed3933806b87752eb5c9e43cd389a";

thread_fn worker(cfg: http::Config) {
    let error = http::serve(cfg) { req, body, out =>
        http::respond(out, 200, "text/plain", "OK");
    };
    http::report(error);
}

fn main() { http::run(http::Config { .. }, worker); }
