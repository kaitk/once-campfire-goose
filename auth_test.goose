import std;
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import http from "github.com/kaitk/goose-http@v0.5.18";
import auth;
import signed_id;

fn main() {
    let expected: u8[20] = [0xde, 0x7c, 0x9b, 0x85, 0xb8, 0xb7, 0x8a, 0xa6, 0xbc, 0x8a,
                           0x7a, 0x36, 0xf7, 0x0a, 0x90, 0x70, 0x1c, 0x9d, 0xb4, 0xd9];
    assert(campfire::hmac_sha1("key", "The quick brown fox jumps over the lazy dog") == expected);
    print("HMAC-SHA1 passed");

    // generates_token_for :transfer, as Python mints it in compare_ui_auth.py (which the Rails image
    // accepts): [id, the salt's last 10 characters], the purpose, HMAC-SHA1 under token_for's key.
    let key = campfire::token_for_key("0123456789abcdef0123456789abcdef0123456789abcdef");
    let digest = "$2a$12$abcdefghijklmnopqrstuvWXYZ0123456789ABCDEFGHIJKLMNOPQ";
    let vector = "eyJfcmFpbHMiOnsiZGF0YSI6WzcsIm1ub3BxcnN0dXYiXSwiZXhwIjoiMjAzMC0wMS0wMVQwMDowMDowMC4wMDBaIiwicHVyIjoiVXNlclxudHJhbnNmZXJcbjE0NDAwIn19--0999f12742909d8602d8522dc086b513ae311966";
    assert(campfire::sign_transfer_token(7, digest, key, "2030-01-01T00:00:00.000Z") == vector);
    var salt: u8[>..] = []; var salted = false;
    assert(campfire::verify_transfer_token(vector, key, "2029-12-31T23:59:59.999Z", salt, salted) == 7);
    assert(salted && salt == "mnopqrstuv");
    // Expired, tampered and under another key.
    var other: u8[>..] = []; var other_salted = false;
    assert(campfire::verify_transfer_token(vector, key, "2030-01-01T00:00:00.001Z", other, other_salted) == 0);
    var tampered: u8[>..] = []; tampered.append(vector); tampered[tampered.len - 1] = '7';
    assert(campfire::verify_transfer_token(tampered, key, "2029-01-01T00:00:00.000Z", other, other_salted) == 0);
    let wrong = campfire::token_for_key("another secret, another secret, another secret!!");
    assert(campfire::verify_transfer_token(vector, wrong, "2029-01-01T00:00:00.000Z", other, other_salted) == 0);
    // A user without a password: [id, nil].
    let unsalted = campfire::sign_transfer_token(8, "", key, "2030-01-01T00:00:00.000Z");
    var none: u8[>..] = []; var none_salted = true;
    assert(campfire::verify_transfer_token(unsalted, key, "2029-01-01T00:00:00.000Z", none, none_salted) == 8);
    assert(!none_salted && none.len == 0);
    print("Transfer tokens passed");
}
