import std;
import os;
import html5;

// What the Rails reference image stores for each body (ActionText::RichText.new(body: body).body.to_html).
fn check(body: const u8[:], stored: const u8[:]) {
    var out: u8[>..] = [];
    campfire::action_text_html(out, body);
    if out != stored { print("body:   ", body); print("rails:  ", stored); print("goose:  ", out); }
    assert(out == stored);
}

fn main() {
    check("Pong <b>bold</b> & more",
          "Pong <b>bold</b> &amp; more");
    check("<p>Direct <em>reply</em><script>alert(1)</script>",
          "<p>Direct <em>reply</em><script>alert(1)</script></p>");
    check("  padded  ",
          "padded");
    check("x\x0D\x0Ay\x0Dz",
          "x\x0Ay\x0Az");
    check("\x00 lead nul \x00",
          "lead nul");
    check("\xEF\xBB\xBF x",
          "x");
    check("a > b",
          "a &gt; b");
    check("x<3 y>2",
          "x&lt;3 y&gt;2");
    check("<",
          "&lt;");
    check("a<b",
          "a");
    check("<p>\xC2\xA0x\xC2\xA0</p>",
          "<p>&nbsp;x&nbsp;</p>");
    check("a&b &amp &AMP; &lt &gt; &quot &apos; &nbsp; &notit; &notin; &#x41; &#65 &#; &#x; &#xFFFFFF; &#xD800; &#x1F600; &#128; &#x9f;",
          "a&amp;b &amp; &amp; &lt; &gt; \x22 ' &nbsp; \xC2\xACit; \xE2\x88\x89 A A &amp;#; &amp;#x; \xEF\xBF\xBD \xEF\xBF\xBD \xF0\x9F\x98\x80 \xE2\x82\xAC \xC5\xB8");
    check("<a href='?a=1&b=2&amp;c&notit=3&copy=4&copy;'>x</a>",
          "<a href=\x22?a=1&amp;b=2&amp;c&amp;notit=3&amp;copy=4\xC2\xA9\x22>x</a>");
    check("<a b='<>\x22&'>t</a>",
          "<a b=\x22&lt;&gt;&quot;&amp;\x22>t</a>");
    check("<div id=a id=b ID=c>x</div>",
          "<div id=\x22a\x22>x</div>");
    check("<p class = \x22x\x22  data-a=1 data-b='2' c d=>y",
          "<p class=\x22x\x22 data-a=\x221\x22 data-b=\x222\x22 c=\x22\x22 d=\x22\x22>y</p>");
    check("<br/><br></br><img src=x />",
          "<br><br><br><img src=\x22x\x22>");
    check("<a href=x><p>y</a>z",
          "<a href=\x22x\x22></a><p><a href=\x22x\x22>y</a>z</p>");
    check("<b><i>x</b>y</i>z",
          "<b><i>x</i></b><i>y</i>z");
    check("<p><b class=x><b class=x><b class=x><b class=x>x</p>y",
          "<p><b class=\x22x\x22><b class=\x22x\x22><b class=\x22x\x22><b class=\x22x\x22>x</b></b></b></b></p><b class=\x22x\x22><b class=\x22x\x22><b class=\x22x\x22>y</b></b></b>");
    check("<a><b><a>x</a></b>",
          "<a><b></b></a><b><a>x</a></b>");
    check("<li>a<li>b<ul><li>c</ul>",
          "<li>a</li><li>b<ul><li>c</li></ul></li>");
    check("<h1>a<h2>b</h1>c",
          "<h1>a</h1><h2>b</h2>c");
    check("<p>a<table><tr><td>x</table>",
          "<p>a</p><table><tbody><tr><td>x</td></tr></tbody></table>");
    check("<table>a<tr>b<td>c</td>d</tr>e</table>",
          "abde<table><tbody><tr><td>c</td></tr></tbody></table>");
    check("<table><colgroup><col></colgroup><col><tr><td>x</table>",
          "<table><colgroup><col></colgroup><colgroup><col></colgroup><tbody><tr><td>x</td></tr></tbody></table>");
    check("<table><input type=hidden><input type=text></table>",
          "<input type=\x22text\x22><table><input type=\x22hidden\x22></table>");
    check("<form><form>x</form>y</form>z",
          "<form>x</form>yz");
    check("<select><option>a<option>b<hr><optgroup>c</select>x",
          "<select><option>a</option><option>b</option><hr><optgroup>c</optgroup></select>x");
    check("<template><p>x</template>y",
          "<template><p>x</p></template>y");
    check("&<template>&lt <col>& <plaintext></th></br>",
          "&amp;<template>&lt; <col> </template>");
    check("<pre>\x0A\x0Ax</pre>",
          "<pre>x</pre>");
    check("<textarea>\x0A\x0Ax</textarea>",
          "<textarea>x</textarea>");
    check("<style>&amp;</style><title>&amp;<b></title>",
          "<style>&amp;</style><title>&amp;&lt;b&gt;</title>");
    check("<script><!--<script>x</script>y</script>z",
          "<script><!--<script>x</script>y</script>z");
    check("<plaintext><b>&amp;</plaintext>",
          "<plaintext><b>&amp;</plaintext></plaintext></plaintext>");
    check("<!-->x<!--->y<!-- a -- b --!>z<!--<!-- -->",
          "<!---->x<!---->y<!-- a -- b -->z<!--<!-- -->");
    check("<?xml version='1.0'?>x",
          "<!--?xml version='1.0'?-->x");
    check("<!DOCTYPE html><p>x",
          "<p>x</p>");
    check("<svg viewbox='0 0 1 1' xlink:href=x><clippath><lineargradient/></clippath></svg>",
          "<svg viewBox=\x220 0 1 1\x22 xlink:href=\x22x\x22><clipPath><linearGradient></linearGradient></clipPath></svg>");
    check("<math definitionurl=x><ms>a</ms></math>",
          "<math definitionURL=\x22x\x22><ms>a</ms></math>");
    check("<svg><foreignObject><p>x</p></foreignObject><p>y</svg>",
          "<svg><foreignObject><p>x</p></foreignObject></svg><p>y</p>");
    check("<svg><b>x</b></svg>",
          "<svg></svg><b>x</b>");
    check("<svg><![CDATA[a<b]]></svg>",
          "<svg><![CDATA[a<b]]></svg>");
    check("<svg>a<![CDATA[b]]>c</svg>",
          "<svg>abc</svg>");
    check("<svg><foreignObject></p>x",
          "<svg><foreignObject><p></p>x</foreignObject></svg>");
    check("<math><mi></p>y",
          "<math><mi><p></p>y</mi></math>");
    check("<b>\x00x</b><svg>\x00</svg>",
          "<b>x</b><svg>\xEF\xBF\xBD</svg>");
    check("&#0;&#13;&#x80;&#x81;",
          "\xEF\xBF\xBD\x0A\xE2\x82\xAC\xC2\x81");
    check("&ThisIsNotAnEntity; &CounterClockwiseContourIntegral; &zwnj;&acE;",
          "&amp;ThisIsNotAnEntity; \xE2\x88\xB3 \xE2\x80\x8C\xE2\x88\xBE\xCC\xB3");
    check("<action-text-attachment sgid=\x22x\x22 content-type=\x22application/vnd.campfire.mention\x22 content=\x22&lt;span&gt;Hi&lt;/span&gt;\x22><span>inner</span></action-text-attachment>",
          "<action-text-attachment sgid=\x22x\x22 content-type=\x22application/vnd.campfire.mention\x22 content=\x22&lt;span&gt;Hi&lt;/span&gt;\x22></action-text-attachment>");
    check("<div class=g><action-text-attachment presentation=gallery sgid=1></action-text-attachment>\x0A<action-text-attachment presentation=gallery sgid=2></action-text-attachment></div>",
          "<div><action-text-attachment presentation=\x22gallery\x22 sgid=\x221\x22></action-text-attachment>\x0A<action-text-attachment presentation=\x22gallery\x22 sgid=\x222\x22></action-text-attachment></div>");
    check("<div class=g><action-text-attachment presentation=gallery sgid=1></action-text-attachment>x<action-text-attachment presentation=gallery sgid=2></action-text-attachment></div>",
          "<div class=\x22g\x22><action-text-attachment presentation=\x22gallery\x22 sgid=\x221\x22></action-text-attachment>x<action-text-attachment presentation=\x22gallery\x22 sgid=\x222\x22></action-text-attachment></div>");
    check("<p><action-text-markdown>**x**</action-text-markdown></p>",
          "<p>**x**</p>");
    check("<p>Check <a href=\x22https://example.com/a?b=c&amp;d=e\x22>this link</a> out</p>",
          "<p>Check <a href=\x22https://example.com/a?b=c&amp;d=e\x22>this link</a> out</p>");
    check("<ul><li><p>one</p></li><li><p>two</p></li></ul>",
          "<ul><li><p>one</p></li><li><p>two</p></li></ul>");
    // Past gumbo's limits Nokogiri raises (Rails answers 500): more than 400 open elements, or 400 attributes on one.
    var deep: u8[>..] = []; for _ in 400 { deep.append("<div>"); }
    var out: u8[>..] = [];
    assert(campfire::action_text_html(out, deep));
    deep.append("<div>"); out.clear(); assert(!campfire::action_text_html(out, deep) && out.len == 0);
    var wide: u8[>..] = []; wide.append("<p"); for i in 400 { format(wide, " a", i, "=1"); } wide.append(">");
    out.clear(); assert(campfire::action_text_html(out, wide));
    wide.clear(); wide.append("<p"); for i in 401 { format(wide, " a", i, "=1"); } wide.append(">");
    out.clear(); assert(!campfire::action_text_html(out, wide));
    // A full-size body of misnested formatting parses in linear time.
    var tangled: u8[>..] = []; while tangled.len < 65000 { tangled.append("<div><b><i><u>x</div>"); }
    let started = clock();
    out.clear(); assert(campfire::action_text_html(out, tangled));
    assert(clock() - started < 1.0);
    print("HTML5 rich text storage passed");
}
