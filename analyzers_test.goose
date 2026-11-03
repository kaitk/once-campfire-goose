import std;
import json;
import analyzers;

// What Blob#analyze saves over {"identified":true} for ffprobe's output, or the analyzer's error.
fn analyzed(probe: const u8[:], video: bool) -> u8[>..] {
    var text: u8[>..] = []; text.append(probe);
    var nodes: json::Node[>..] = []; var strings: u8[>..] = [];
    let root, error = json::parse(text, nodes, strings);
    assert(error.len == 0);
    var members: u8[][>..] = []; var why: u8[>..] = [];
    let extracted = if video { campfire::video_metadata(root, members, why) } else { campfire::audio_metadata(root, members, why) };
    if !extracted { return str("error: ", why); }
    return campfire::merged_metadata("{\"identified\":true}", members);
}

fn float_text(v: f64) -> u8[>..] { var out: u8[>..] = []; campfire::ruby_float(out, v); return out; }

fn main() {
    // The Rails reference's alpha-centuri.mov, as its VideoAnalyzer saved it.
    assert(analyzed("{\"streams\":[{\"codec_type\":\"video\",\"width\":320,\"height\":180,\"display_aspect_ratio\":\"16:9\",\"duration\":\"65.840000\"}],\"format\":{\"duration\":\"65.9\"}}", true)
        == "{\"identified\":true,\"width\":320.0,\"height\":180.0,\"duration\":65.84,\"display_aspect_ratio\":[16,9],\"audio\":false,\"video\":true,\"analyzed\":true}");
    // A display matrix's quarter turn swaps width and height; the container's duration stands in.
    assert(analyzed("{\"streams\":[{\"codec_type\":\"video\",\"width\":1920,\"height\":1080,\"side_data_list\":[{\"side_data_type\":\"Display Matrix\",\"rotation\":-90}]},{\"codec_type\":\"audio\"}],\"format\":{\"duration\":\"3.5\"}}", true)
        == "{\"identified\":true,\"width\":1080.0,\"height\":1920.0,\"duration\":3.5,\"angle\":-90,\"audio\":true,\"video\":true,\"analyzed\":true}");
    // The rotate tag wins over the display matrix; the turned width is the display height.
    assert(analyzed("{\"streams\":[{\"codec_type\":\"video\",\"width\":1440,\"height\":1080,\"display_aspect_ratio\":\"16:9\",\"tags\":{\"rotate\":\"90\"},\"side_data_list\":[{\"side_data_type\":\"Display Matrix\",\"rotation\":180}]}]}", true)
        == "{\"identified\":true,\"width\":810.0,\"height\":1440.0,\"angle\":90,\"display_aspect_ratio\":[16,9],\"audio\":false,\"video\":true,\"analyzed\":true}");
    // A 0:1 aspect ratio is none; a null field is a missing one.
    assert(analyzed("{\"streams\":[{\"codec_type\":\"video\",\"width\":64,\"height\":48,\"display_aspect_ratio\":\"0:1\",\"duration\":null}]}", true)
        == "{\"identified\":true,\"width\":64.0,\"height\":48.0,\"audio\":false,\"video\":true,\"analyzed\":true}");
    // ffprobe's answer for a file it can't read, or no ffprobe at all.
    assert(analyzed("{}", true) == "{\"identified\":true,\"audio\":false,\"video\":false,\"analyzed\":true}");
    assert(analyzed("{}", false) == "{\"identified\":true,\"analyzed\":true}");
    // Where Ruby's Integer() and Float() raise, the analysis fails.
    assert(starts_with(analyzed("{\"streams\":[{\"codec_type\":\"video\",\"display_aspect_ratio\":\"wide\"}]}", true), "error: "));
    assert(starts_with(analyzed("{\"streams\":[{\"codec_type\":\"video\",\"display_aspect_ratio\":\"16\"}]}", true), "error: "));
    assert(starts_with(analyzed("{\"streams\":[{\"codec_type\":\"video\",\"width\":\"N/A\"}]}", true), "error: "));
    // Integer() reads Ruby's radix prefixes.
    assert(analyzed("{\"streams\":[{\"codec_type\":\"video\",\"tags\":{\"rotate\":\" 0x5A \"}}]}", true)
        == "{\"identified\":true,\"angle\":90,\"audio\":false,\"video\":true,\"analyzed\":true}");
    // AudioAnalyzer: the stream's tags as they are, with ActiveSupport's escapes.
    assert(analyzed("{\"streams\":[{\"codec_type\":\"audio\",\"duration\":\"1.000000\",\"bit_rate\":\"128000\",\"sample_rate\":\"44100\",\"tags\":{\"title\":\"A <b> & \\\"c\\\" é\",\"n\":1}}],\"format\":{\"tags\":{\"title\":\"x\"}}}", false)
        == "{\"identified\":true,\"duration\":1.0,\"bit_rate\":128000,\"sample_rate\":44100,\"tags\":{\"title\":\"A \\u003cb\\u003e \\u0026 \\\"c\\\" é\",\"n\":1},\"analyzed\":true}");
    // Merging keeps the stored members' order and replaces the values analyzed again.
    var members: u8[][>..] = [];
    members.push(campfire::member_entry("width", "2.0"));
    assert(campfire::merged_metadata("{\"identified\":true,\"analyzed\":false,\"width\":1,\"note\":\"a<b\"}", members)
        == "{\"identified\":true,\"analyzed\":true,\"width\":2.0,\"note\":\"a\\u003cb\"}");
    // Float#to_s.
    assert(float_text(1e16) == "1.0e+16" && float_text(1e15) == "1000000000000000.0" && float_text(0.0001) == "0.0001");
    assert(float_text(0.00001) == "1.0e-05" && float_text(123.25) == "123.25" && float_text(0.1 + 0.2) == "0.30000000000000004");
    assert(float_text(-2.5e-300) == "-2.5e-300" && float_text(0.0) == "0.0" && float_text(810.0) == "810.0");
    print("video and audio analysis passed");
}
