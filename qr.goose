namespace campfire;
import std;

// QR codes as QrCodeController draws them: RQRCode::QRCode.new(url) (rqrcode_core 2.1.0, error correction
// level H, one segment of the mode the whole text allows, the smallest version it fits) and
// as_svg(viewbox: true, fill: :white, color: :black). rqrcode_core chooses its mask by its own penalty
// rules, not the standard's, so this follows its code rather than libqrencode's.

// rqrcode_core's RS block table for level H: per version, up to two groups of (count, total, data).
const QR_H_BLOCKS: i64[240] = [1, 26, 9, 0, 0, 0, 1, 44, 16, 0, 0, 0, 2, 35, 13, 0, 0, 0, 4, 25, 9, 0, 0, 0, 2, 33, 11, 2, 34, 12, 4, 43, 15, 0, 0, 0, 4, 39, 13, 1, 40, 14, 4, 40, 14, 2, 41, 15, 4, 36, 12, 4, 37, 13, 6, 43, 15, 2, 44, 16, 3, 36, 12, 8, 37, 13, 7, 42, 14, 4, 43, 15, 12, 33, 11, 4, 34, 12, 11, 36, 12, 5, 37, 13, 11, 36, 12, 7, 37, 13, 3, 45, 15, 13, 46, 16, 2, 42, 14, 17, 43, 15, 2, 42, 14, 19, 43, 15, 9, 39, 13, 16, 40, 14, 15, 43, 15, 10, 44, 16, 19, 46, 16, 6, 47, 17, 34, 37, 13, 0, 0, 0, 16, 45, 15, 14, 46, 16, 30, 46, 16, 2, 47, 17, 22, 45, 15, 13, 46, 16, 33, 46, 16, 4, 47, 17, 12, 45, 15, 28, 46, 16, 11, 45, 15, 31, 46, 16, 19, 45, 15, 26, 46, 16, 23, 45, 15, 25, 46, 16, 23, 45, 15, 28, 46, 16, 19, 45, 15, 35, 46, 16, 11, 45, 15, 46, 46, 16, 59, 46, 16, 1, 47, 17, 22, 45, 15, 41, 46, 16, 2, 45, 15, 64, 46, 16, 24, 45, 15, 46, 46, 16, 42, 45, 15, 32, 46, 16, 10, 45, 15, 67, 46, 16, 20, 45, 15, 61, 46, 16];
// QRMAXBITS[:h]
const QR_H_MAX_BITS: i64[40] = [72, 128, 208, 288, 368, 480, 528, 688, 800, 976, 1120, 1264, 1440, 1576, 1784, 2024, 2264, 2504, 2728, 3080, 3248, 3536, 3712, 4112, 4304, 4768, 5024, 5288, 5608, 5960, 6344, 6760, 7208, 7688, 7888, 8432, 8768, 9136, 9776, 10208];
// QRUtil::PATTERN_POSITION_TABLE, seven a version, 0 for none.
const QR_ALIGNMENT: i64[280] = [0, 0, 0, 0, 0, 0, 0, 6, 18, 0, 0, 0, 0, 0, 6, 22, 0, 0, 0, 0, 0, 6, 26, 0, 0, 0, 0, 0, 6, 30, 0, 0, 0, 0, 0, 6, 34, 0, 0, 0, 0, 0, 6, 22, 38, 0, 0, 0, 0, 6, 24, 42, 0, 0, 0, 0, 6, 26, 46, 0, 0, 0, 0, 6, 28, 50, 0, 0, 0, 0, 6, 30, 54, 0, 0, 0, 0, 6, 32, 58, 0, 0, 0, 0, 6, 34, 62, 0, 0, 0, 0, 6, 26, 46, 66, 0, 0, 0, 6, 26, 48, 70, 0, 0, 0, 6, 26, 50, 74, 0, 0, 0, 6, 30, 54, 78, 0, 0, 0, 6, 30, 56, 82, 0, 0, 0, 6, 30, 58, 86, 0, 0, 0, 6, 34, 62, 90, 0, 0, 0, 6, 28, 50, 72, 94, 0, 0, 6, 26, 50, 74, 98, 0, 0, 6, 30, 54, 78, 102, 0, 0, 6, 28, 54, 80, 106, 0, 0, 6, 32, 58, 84, 110, 0, 0, 6, 30, 58, 86, 114, 0, 0, 6, 34, 62, 90, 118, 0, 0, 6, 26, 50, 74, 98, 122, 0, 6, 30, 54, 78, 102, 126, 0, 6, 26, 52, 78, 104, 130, 0, 6, 30, 56, 82, 108, 134, 0, 6, 34, 60, 86, 112, 138, 0, 6, 30, 58, 86, 114, 142, 0, 6, 34, 62, 90, 118, 146, 0, 6, 30, 54, 78, 102, 126, 150, 6, 24, 50, 76, 102, 128, 154, 6, 28, 54, 80, 106, 132, 158, 6, 32, 58, 84, 110, 136, 162, 6, 26, 54, 82, 110, 138, 166, 6, 30, 58, 86, 114, 142, 170];
let QR_ALPHANUMERIC = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";
let QR_NONE: u8 = 2;

struct QrBits { length: i64 = 0, bytes: u8[>..] = [] }

fn qr_put(buffer: QrBits&, num: i64, length: i64) {
    for i in length {
        if buffer.length / 8 >= buffer.bytes.len { buffer.bytes.push(0); }
        if ((num >> (length - i - 1)) & 1) == 1 { buffer.bytes[buffer.length / 8] |= (128 >> (buffer.length % 8)) as u8; }
        buffer.length += 1;
    }
}

// QRUtil.get_length_in_bits for modes 1 (number), 2 (alphanumeric) and 4 (8-bit bytes).
fn qr_count_bits(mode: i64, version: i64) -> i64 {
    let range = if version <= 9 { 0 } else if version <= 26 { 1 } else { 2 };
    if mode == 1 { return [10, 12, 14][range]; }
    if mode == 2 { return [9, 11, 13][range]; }
    return [8, 16, 16][range];
}

fn qr_bit_digits(value: i64) -> i64 {
    var digits: i64 = 0; var rest = value;
    while rest != 0 { digits += 1; rest = rest >> 1; }
    return digits;
}

// QRUtil.get_bch_format_info and get_bch_version.
fn qr_bch(data: i64, generator: i64, shift: i64) -> i64 {
    var d = data << shift;
    while qr_bit_digits(d) - qr_bit_digits(generator) >= 0 { d = d ^ (generator << (qr_bit_digits(d) - qr_bit_digits(generator))); }
    return (data << shift) | d;
}

// QRMASKCOMPUTATIONS
fn qr_mask(pattern: i64, i: i64, j: i64) -> bool {
    if pattern == 0 { return (i + j) % 2 == 0; }
    if pattern == 1 { return i % 2 == 0; }
    if pattern == 2 { return j % 3 == 0; }
    if pattern == 3 { return (i + j) % 3 == 0; }
    if pattern == 4 { return (i / 2 + j / 3) % 2 == 0; }
    if pattern == 5 { return (i * j) % 2 + (i * j) % 3 == 0; }
    if pattern == 6 { return ((i * j) % 2 + (i * j) % 3) % 2 == 0; }
    return ((i * j) % 3 + (i + j) % 2) % 2 == 0;
}

fn qr_gmul(a: i64, b: i64, exp: const i64[:], log: const i64[:]) -> i64 {
    if a == 0 || b == 0 { return 0; }
    return exp[(log[a] + log[b]) % 255];
}

// QRCode.create_data and create_bytes: the codewords, data then error correction, interleaved.
fn qr_codewords(text: const u8[:], mode: i64, version: i64, out: i64[>..]&) -> bool {
    var groups: i64[>..] = [];
    var max_bits: i64 = 0; var total: i64 = 0;
    for g in 2 {
        let at = (version - 1) * 6 + g * 3;
        for k in QR_H_BLOCKS[at] { groups.push(QR_H_BLOCKS[at + 1]); groups.push(QR_H_BLOCKS[at + 2]); max_bits += QR_H_BLOCKS[at + 2] * 8; total += QR_H_BLOCKS[at + 1]; }
    }
    var buffer = QrBits { .. };
    qr_put(buffer, mode, 4); qr_put(buffer, text.len, qr_count_bits(mode, version));
    if mode == 1 {
        var i: i64 = 0;
        while i < text.len {
            let n = min(3, text.len - i); var value: i64 = 0;
            for k in n { value = value * 10 + (text[i + k] - '0'); }
            qr_put(buffer, value, if n == 3 { 10 } else if n == 2 { 7 } else { 4 });
            i += 3;
        }
    } else if mode == 2 {
        var i: i64 = 0;
        while i < text.len {
            if i == text.len - 1 { qr_put(buffer, find(QR_ALPHANUMERIC, text[i..i + 1]), 6); }
            else { qr_put(buffer, find(QR_ALPHANUMERIC, text[i..i + 1]) * 45 + find(QR_ALPHANUMERIC, text[i + 1..i + 2]), 11); }
            i += 2;
        }
    } else { for c in text { qr_put(buffer, c, 8); } }
    if buffer.length + 4 <= max_bits { qr_put(buffer, 0, 4); }
    if buffer.length > max_bits { return false; }
    while buffer.length % 8 != 0 { qr_put(buffer, 0, 1); }
    while buffer.length < max_bits { qr_put(buffer, 236, 8); if buffer.length < max_bits { qr_put(buffer, 17, 8); } }

    var exp: i64[256] = [0; 256]; var log: i64[256] = [0; 256];
    for i in 256 { exp[i] = if i < 8 { 1 << i } else { exp[i - 4] ^ exp[i - 5] ^ exp[i - 6] ^ exp[i - 8] }; }
    for i in 255 { log[exp[i]] = i; }
    let blocks = groups.len / 2;
    var data: i64[>..] = []; var ecc: i64[>..] = []; var starts: i64[>..] = []; var ecc_starts: i64[>..] = [];
    var max_data: i64 = 0; var max_ecc: i64 = 0; var offset: i64 = 0;
    for b in blocks {
        let size = groups[2 * b + 1]; let ecc_size = groups[2 * b] - size;
        max_data = max(max_data, size); max_ecc = max(max_ecc, ecc_size);
        starts.push(data.len); ecc_starts.push(ecc.len);
        for i in size { data.push(buffer.bytes[offset + i]); }
        // The generator polynomial (x - α^0)...(x - α^(n-1)), highest degree first, and the remainder.
        var generator: i64[>..] = []; generator.push(1);
        for i in ecc_size {
            var next: i64[>..] = []; next.resize(generator.len + 1, 0);
            for j in generator.len { next[j] ^= generator[j]; next[j + 1] ^= qr_gmul(generator[j], exp[i], exp, log); }
            generator.clear(); generator.append(next);
        }
        var remainder: i64[>..] = []; remainder.resize(ecc_size, 0);
        for i in size {
            let factor = data[starts[b] + i] ^ remainder[0];
            for j in ecc_size - 1 { remainder[j] = remainder[j + 1]; }
            remainder[ecc_size - 1] = 0;
            for j in ecc_size { remainder[j] ^= qr_gmul(generator[j + 1], factor, exp, log); }
        }
        ecc.append(remainder);
        offset += size;
    }
    for i in max_data { for b in blocks { if i < groups[2 * b + 1] { out.push(data[starts[b] + i]); } } }
    for i in max_ecc { for b in blocks { if i < groups[2 * b] - groups[2 * b + 1] { out.push(ecc[ecc_starts[b] + i]); } } }
    return out.len == total;
}

fn qr_set(modules: u8[>..]&, n: i64, row: i64, col: i64, dark: bool) { modules[row * n + col] = if dark { 1 } else { 0 }; }

// make_impl: the function patterns, format and version information, and the masked data.
fn qr_place(modules: u8[>..]&, common: const u8[:], n: i64, version: i64, codewords: const i64[:], test: bool, mask: i64) {
    modules.clear(); modules.append(common);
    let bits = qr_bch(2 << 3 | mask, 1335, 10) ^ 21522;
    for i in 15 {
        let dark = !test && ((bits >> i) & 1) == 1;
        qr_set(modules, n, if i < 6 { i } else if i < 8 { i + 1 } else { n - 15 + i }, 8, dark);
        qr_set(modules, n, 8, if i < 8 { n - i - 1 } else if i < 9 { 15 - i } else { 15 - i - 1 }, dark);
    }
    qr_set(modules, n, n - 8, 8, !test);
    if version >= 7 {
        let info = qr_bch(version, 7973, 12);
        for i in 18 {
            let dark = !test && ((info >> i) & 1) == 1;
            qr_set(modules, n, i / 3, i % 3 + n - 11, dark); qr_set(modules, n, i % 3 + n - 11, i / 3, dark);
        }
    }
    var inc: i64 = -1; var row = n - 1; var bit: i64 = 7; var index: i64 = 0;
    var column = n - 1;
    while column >= 1 {
        let col = if column <= 6 { column - 1 } else { column };
        loop {
            for c in 2 {
                if modules[row * n + col - c] == QR_NONE {
                    var dark = index < codewords.len && ((codewords[index] >> bit) & 1) == 1;
                    if qr_mask(mask, row, col - c) { dark = !dark; }
                    qr_set(modules, n, row, col - c, dark);
                    bit -= 1;
                    if bit == -1 { index += 1; bit = 7; }
                }
            }
            row += inc;
            if row < 0 || n <= row { row -= inc; inc = -inc; break; }
        }
        column -= 2;
    }
}

// QRUtil.get_lost_points, times the module count, which keeps the dark ratio's points whole.
fn qr_lost_points(modules: const u8[:], n: i64) -> i64 {
    var points: i64 = 0;
    for row in n {
        for col in n {
            let dark = modules[row * n + col]; var same: i64 = 0;
            for dr in 3 {
                for dc in 3 {
                    let r = row + dr - 1; let c = col + dc - 1;
                    if (dr != 1 || dc != 1) && r >= 0 && r < n && c >= 0 && c < n && modules[r * n + c] == dark { same += 1; }
                }
            }
            if same > 5 { points += 3 + same - 5; }
        }
    }
    for row in n - 1 {
        for col in n - 1 {
            let v = modules[row * n + col];
            if v == modules[(row + 1) * n + col] && v == modules[row * n + col + 1] && v == modules[(row + 1) * n + col + 1] { points += 3; }
        }
    }
    let pattern: u8[7] = [1, 0, 1, 1, 1, 0, 1];
    for a in n {
        for b in n - 6 {
            var across = true; var down = true;
            for k in 7 {
                if modules[a * n + b + k] != pattern[k] { across = false; }
                if modules[(b + k) * n + a] != pattern[k] { down = false; }
            }
            if across { points += 40; }
            if down { points += 40; }
        }
    }
    var dark: i64 = 0; for m in modules { if m == 1 { dark += 1; } }
    let total = n * n; let delta = 100 * dark - 50 * total;
    return points * total + 2 * (if delta < 0 { -delta } else { delta });
}

// The modules of RQRCode::QRCode.new(text), n by n, 1 for dark; n is 0 for text too long for version 40.
fn qr_modules(text: const u8[:], modules: u8[>..]&) -> i64 {
    var numeric = true; var alphanumeric = true;
    for c, k in text {
        if c < '0' || c > '9' { numeric = false; }
        if find(QR_ALPHANUMERIC, text[k..k + 1]) < 0 { alphanumeric = false; }
    }
    let mode: i64 = if numeric { 1 } else if alphanumeric { 2 } else { 4 };
    let content = if mode == 1 { text.len / 3 * 10 + [0, 4, 7][text.len % 3] } else if mode == 2 { text.len / 2 * 11 + text.len % 2 * 6 } else { text.len * 8 };
    var version: i64 = 1;
    while version <= 40 && 4 + qr_count_bits(mode, version) + content >= QR_H_MAX_BITS[version - 1] { version += 1; }
    guard version <= 40 else { return 0; }
    var codewords: i64[>..] = [];
    guard qr_codewords(text, mode, version, codewords) else { return 0; }
    let n = version * 4 + 17;
    var common: u8[>..] = []; common.resize(n * n, QR_NONE);
    for probe in 3 {
        let top = if probe == 1 { n - 7 } else { 0 }; let left = if probe == 2 { n - 7 } else { 0 };
        for r in 9 {
            for c in 9 {
                let rr = r - 1; let cc = c - 1;
                if top + rr < 0 || top + rr >= n || left + cc < 0 || left + cc >= n { continue; }
                let dark = rr >= 0 && rr <= 6 && (cc == 0 || cc == 6) || cc >= 0 && cc <= 6 && (rr == 0 || rr == 6) || rr >= 2 && rr <= 4 && cc >= 2 && cc <= 4;
                qr_set(common, n, top + rr, left + cc, dark);
            }
        }
    }
    let positions = QR_ALIGNMENT[(version - 1) * 7..version * 7];
    for row in positions {
        if row == 0 { continue; }
        for col in positions {
            if col == 0 || common[row * n + col] != QR_NONE { continue; }
            for r in 5 { for c in 5 { qr_set(common, n, row + r - 2, col + c - 2, r == 0 || r == 4 || c == 0 || c == 4 || r == 2 && c == 2); } }
        }
    }
    var i: i64 = 8;
    while i < n - 8 { qr_set(common, n, i, 6, i % 2 == 0); qr_set(common, n, 6, i, i % 2 == 0); i += 1; }
    var best: i64 = 0; var lowest: i64 = 0;
    for mask in 8 {
        qr_place(modules, common, n, version, codewords, true, mask);
        let lost = qr_lost_points(modules, n);
        if mask == 0 || lowest > lost { lowest = lost; best = mask; }
    }
    qr_place(modules, common, n, version, codewords, false, best);
    return n;
}

// as_svg(viewbox: true, fill: :white, color: :black); false for text too long to encode.
fn qr_svg(text: const u8[:], out: u8[>..]&) -> bool {
    var modules: u8[>..] = [];
    let n = qr_modules(text, modules);
    guard n > 0 else { return false; }
    let size = n * 11;
    format(out, "<?xml version=\"1.0\" standalone=\"yes\"?><svg version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:ev=\"http://www.w3.org/2001/xml-events\" viewBox=\"0 0 ",
        size, " ", size, "\" shape-rendering=\"crispEdges\"><rect width=\"", size, "\" height=\"", size, "\" x=\"0\" y=\"0\" fill=\"white\"/>");
    for row in n { for col in n { if modules[row * n + col] == 1 { format(out, "<rect width=\"11\" height=\"11\" x=\"", col * 11, "\" y=\"", row * 11, "\" fill=\"black\"/>"); } } }
    out.append("</svg>");
    return true;
}
