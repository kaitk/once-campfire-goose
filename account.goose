namespace campfire;
import std;
import os;
import http;
import json;
import hash;
import sqlite;
import database;
import html;
import messages;
import signed_id;
import setup;
import cable;
import storage;
import media;
import avatars;
import route_support;
import admin_routes;
import room_pages;
import qr;
import search;
import view_types;
import view_data;
import view_helpers;
import views_generated;

// The profile (Users::ProfilesController), account settings (AccountsController), custom styles
// (Accounts::CustomStylesController), chat bots (Accounts::BotsController, Accounts::Bots::KeysController)
// and QR codes (QrCodeController), after the Rails reference at 90b330024dec3e757c79b6a7e6568f93da8e3148.

// User::Transferable: the signed id a session transfer link carries, valid for four hours.
let TRANSFER_PURPOSE = "user/transfer";

fn transfer_url(db, req: const http::Request&, user: i64, key: const u8[:]) -> u8[>..] {
    let expiry = sql_value(db,"SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+4 hours')",[]);
    return str(request_base(req),"/session/transfers/",sign_id(user,TRANSFER_PURPOSE,key,expiry));
}

// Rails.application.config.app_version: APP_VERSION, else GIT_REVISION, else "0".
fn app_version() -> u8[>..] {
    var version: u8[>..] = [];
    if env("APP_VERSION",version) && version.len > 0 { return version; }
    version.clear();
    if env("GIT_REVISION",version) && version.len > 0 { return version; }
    return str("0");
}

fn version_footer() -> u8[>..] {
    var out: u8[>..] = [];
    out.append("  <div class=\"txt-align-center center margin-block-double txt-subtle\">Campfire&trade; version <span class=\"version-badge\">");
    escape(out,app_version()); out.append("</span></div>\n");
    return out;
}

// `link_to_zoom_qr_code(url)`
fn zoom_qr_link(url: const u8[:], label: const u8[:]) -> u8[>..] {
    var body: u8[>..] = []; body.append("\n  <span class=\"for-screen-reader\">"); escape(body,label); body.append("</span>\n  ");
    body.append(image_html("qr-code.svg",[html_attr("aria-hidden","true"),html_attr("size",20),html_attr("class","colorize--black")])); body.push('\n');
    return block_link_to_zoom_qr_code(url,body);
}

fn icon_body(label: const u8[:], icon: const u8[:], classes: const u8[:]) -> u8[>..] {
    var body: u8[>..] = []; body.append("\n  <span class=\"for-screen-reader\">"); escape(body,label); body.append("</span>\n  ");
    body.append(image_html(icon,[html_attr("aria-hidden","true"),html_attr("size",20),html_attr("class",classes)])); body.push('\n');
    return body;
}

// users/profiles/_transfer, for the profile and, for administrators, the user page.
fn transfer_html(out: u8[>..]&, url: const u8[:], own: bool) {
    out.append("\n<fieldset>\n  <legend class=\"gap\">\n");
    for icon in ["laptop.svg","transfer.svg","mobile-phone.svg"] {
        out.append("    "); out.append(image_html(icon,[html_attr("aria-hidden","true"),html_attr("size",36),html_attr("class","colorize--black")])); out.push('\n');
    }
    out.append("  </legend>\n\n  <div class=\"flex flex-column gap\">\n");
    if !own {
        out.append("      <div class=\"flex align-center gap justify-center\">\n        ");
        out.append(image_html("crown.svg",[html_attr("size",16),html_attr("aria-hidden","true"),html_attr("class","flex-item-no-shrink colorize--black")]));
        out.append("\n        <label for=\"session_transfer_url\">Share to get them back into their account</label>\n      </div>\n");
    } else {
        out.append("      <label for=\"session_transfer_url\" class=\"for-screen-reader\">Use this link to login automatically on another device</label>\n");
    }
    out.append("\n    <input type=\"text\" class=\"input\" value=\""); escape(out,url); out.append("\" id=\"session_transfer_url\" readonly>\n\n    <div class=\"flex align-center center gap\">\n      ");
    out.append(zoom_qr_link(url,"Show auto-login QR code")); out.append("\n      ");
    out.append(block_button_to_copy_to_clipboard(url,icon_body("Copy auto-login link","copy-paste.svg","flex-item-no-shrink colorize--black"))); out.append("\n      ");
    out.append(block_web_share_session_button(url,"Your sign-in link","This is your own private sign-in URL, DO NOT SHARE IT. Use it to sign-in on another device or if you get locked out.",
        icon_body("Share auto-login link","share.svg","flex-item-no-shrink colorize--black")));
    out.append("    </div>\n  </div>\n</fieldset>\n");
}

// `link_back`: the referrer, unless it is this page, else the root.
fn link_back_html(out: u8[>..]&, req: const http::Request&) {
    let referer, has_referer = http::field_of(req,"Referer");
    let back: u8[>..] = if has_referer && referer.len > 0 && referer != str(request_base(req),req.target) { str(referer) } else { str("/") };
    link_back_to(out,back);
}

fn back_nav(back: const u8[:]) -> u8[>..] {
    var nav: u8[>..] = []; nav.append("  <div class=\"flex-item-justify-start\">\n    "); link_back_to(nav,back); nav.append("\n  </div>\n");
    return nav;
}

fn last_room_path(db, user: i64, req: const http::Request&) -> u8[>..] {
    let last = last_room_visited(db,user,req);
    return if last > 0 { str("/rooms/",last) } else { str("/") };
}

// `redirect_to url, notice:`, the flash in the session cookie (search.goose's) until a page shows it.
fn redirect_with_notice(out: http::Reply, req: const http::Request&, path: const u8[:], notice: const u8[:], cookie_key: const u8[:]) {
    http::start(out,302);
    http::field(out,"Location",str(request_base(req),path));
    if notice.len > 0 { http::field(out,"Set-Cookie",flash_cookie("notice",notice,cookie_key)); }
    http::finish(out,http::TEXT,"Redirecting");
}

// A page in the application layout with the flash a redirect left, which it then clears.
fn respond_with_flash(out: http::Reply, req: const http::Request&, ctx: ViewContext&, bytes: u8[>..]&, cookie_key: const u8[:]) {
    if !read_flash(req,cookie_key,ctx,bytes) { respond_page(out,req,ctx); return; }
    var page: u8[>..] = [];
    let frame, framed = http::field_of(req,"Turbo-Frame");
    if framed { page.append("<html>\n  <head>\n    "); page.append(ctx.page_head); page.append("\n  </head>\n  <body>\n    "); page.append(ctx.page_content); page.append("\n  </body>\n</html>\n"); }
    else { render_page_html(page,ctx); }
    http::start(out,200);
    http::field(out,"Content-Type","text/html; charset=utf-8");
    http::field(out,"Set-Cookie",FLASH_CLEARED);
    http::finish(out,http::NO_TYPE,page);
}

// --- Parameters ----------------------------------------------------------------------------------

// A parameter of a urlencoded or multipart form: the last of a urlencoded field, as Rails keeps it.
fn param_of(req: const http::Request&, body: const u8[:], name: const u8[:], out: u8[>..]&) -> bool {
    out.clear();
    if content_type_is(req,"multipart/form-data") {
        let data, fields, found = http::find_part(req,body,name);
        if found != http::PART_FOUND { return false; }
        out.append(data); return true;
    }
    return form_last(body,name,out);
}

// params.require(key): some key[...] parameter.
fn has_params(req: const http::Request&, body: const u8[:], prefix: const u8[:], names: const (const u8[:])[:]) -> bool {
    if content_type_is(req,"multipart/form-data") {
        for name in names { let data, fields, found = http::find_part(req,body,name); if found == http::PART_FOUND { return true; } }
        return false;
    }
    return form_has_prefix(body,prefix);
}

// An uploaded file part: staged in storage before the transaction, whose rows save_upload writes.
// 0 without one, 1 staged, 400 for a malformed body, 500 if it cannot be written.
fn staged_file(req: const http::Request&, body: const u8[:], name: const u8[:], storage: const u8[:], upload: Upload&) -> i32 {
    if !content_type_is(req,"multipart/form-data") { return 0; }
    let data, fields, found = http::find_part(req,body,name);
    if found == http::PART_TYPE || found == http::PART_BAD { return 400; }
    if found != http::PART_FOUND || data.len == 0 { return 0; }
    let part, raw_filename, disposed = http::disposition(fields);
    if raw_filename.len == 0 { return 0; }
    let declared, typed = http::field_in(fields,"content-type");
    if !stage_upload(storage,data,unquote_filename(raw_filename),declared,upload) { return 500; }
    return 1;
}

// ActiveModel::Type::Boolean: blank is nil, the false values false, anything else true.
fn boolean_json(value: const u8[:]) -> const u8[:] {
    if value.len == 0 { return "null"; }
    for falsy in ["0","f","F","false","FALSE","off","OFF"] { if value == falsy { return "false"; } }
    return "true";
}

// has_json's before_save: the schema's defaults for keys the settings lack.
let SETTINGS_DEFAULTS = "UPDATE accounts SET settings=json_set(COALESCE(settings,'{}'),'$.restrict_room_creation_to_administrators',json('false')) WHERE json_type(COALESCE(settings,'{}'),'$.restrict_room_creation_to_administrators') IS NULL";

// --- Pages ---------------------------------------------------------------------------------------

// users/profiles/_membership
fn membership_html(out: u8[>..]&, room: i64, kind: const u8[:], name: const u8[:], involvement: const u8[:]) {
    format(out,"<li class=\"flex align-center gap margin-none min-width membership-item\">\n  <a class=\"overflow-ellipsis fill-shade txt-primary txt-undecorated\" href=\"/rooms/",room,"\">\n    <strong>");
    escape(out,name); out.append("</strong>\n</a>\n  <hr class=\"separator\" aria-hidden=\"true\">\n\n  <span class=\"txt-small\">\n    ");
    let key = room_param_key(kind); let label = str("involvement_label_",key,"_",room);
    format(out,"<turbo-frame id=\"involvement_",key,"_",room,"\">\n      <form class=\"button_to\" method=\"post\" action=\"/rooms/",room,"/involvement?involvement=",next_involvement(kind == "Rooms::Direct",involvement),"\"><input type=\"hidden\" name=\"_method\" value=\"put\" />");
    out.append("<button role=\"checkbox\" aria-checked=\"true\" aria-labelledby=\""); out.append(label); out.append("\" tabindex=\"0\" class=\"btn "); escape(out,involvement);
    out.append("\" type=\"submit\">"); out.append(image_html(str("notification-bell-",involvement,".svg"),[html_attr("aria-hidden","true"),html_attr("size",20)]));
    out.append("<span class=\"for-screen-reader\" id=\""); out.append(label); out.append("\">"); out.append(involvement_label(involvement)); out.append("</span></button></form>\n</turbo-frame>  </span>\n</li>\n");
}

fn profile_form_start(out: u8[>..]&, classes: const u8[:], multipart: bool) {
    out.append("<form ");
    if classes.len > 0 { out.append("class=\""); out.append(classes); out.append("\" "); }
    out.append("data-controller=\"form\" ");
    if multipart { out.append("enctype=\"multipart/form-data\" "); }
    out.append("action=\"/users/me/profile\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\" />\n");
}

fn submit_button(out: u8[>..]&) {
    out.append("<button class=\"btn btn--reversed center txt-large\" type=\"submit\">"); out.append(image_html("check.svg",[html_attr("aria-hidden","true"),html_attr("size",20)]));
    out.append("<span class=\"for-screen-reader\">Save changes</span></button>\n");
}

fn profile_field(out: u8[>..]&, ctx: const ViewContext&, translation: const u8[:], align: const u8[:], label_classes: const u8[:], field: const u8[:], icon: const u8[:]) {
    out.append("      <div class=\"flex "); out.append(align); out.append(" gap\">\n        "); out.append(translation_button_html(ctx,translation));
    out.append("\n\n        <label class=\""); out.append(label_classes); out.append("\">\n          "); out.append(field); out.append("\n          ");
    out.append(image_html(icon,[html_attr("aria-hidden","true"),html_attr("size",24),html_attr("class","colorize--black")])); out.append("\n        </label>\n      </div>\n\n");
}

// users/profiles/show
fn profile_page(db, ctx: ViewContext&, bytes: u8[>..]&, req: const http::Request&, user: i64, avatar_key: const u8[:]) -> u8[>..] {
    let rows = sql_rows(db,"SELECT name,COALESCE(email_address,''),bio,email_address IS NOT NULL FROM users WHERE id=?",[sql_text(user)]);
    let name = rows_col(rows,0,0); let email = rows_col(rows,0,1); let bio = rows_col(rows,0,2); let has_email = rows_col(rows,0,3) == "1";
    ctx.title = view_keep(bytes,name);
    var nav: u8[>..] = []; nav.append("  <div class=\"flex-item-justify-start\">\n    "); link_back_html(nav,req);
    nav.append("\n  </div>\n\n  <div class=\"flex-item-justify-end\">\n    <form data-controller=\"sessions\" action=\"/session\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"delete\" />\n");
    nav.append("      <input type=\"hidden\" name=\"push_subscription_endpoint\" id=\"push_subscription_endpoint\" data-sessions-target=\"pushSubscriptionEndpoint\" />\n\n      <button class=\"btn\" data-action=\"sessions#logout:prevent\">\n        ");
    nav.append(image_html("logout.svg",[html_attr("aria-hidden","true")])); nav.append("\n        <span class=\"for-screen-reader\">Log out</span>\n      </button>\n</form>  </div>\n");
    ctx.page_nav = view_keep(bytes,nav);

    var out: u8[>..] = [];
    format(out,"\n<section class=\"panel flex flex-column gap\" style=\"view-transition-name: avatar-",user,"\">\n  ");
    render_install_instructions_html(out,ctx);
    out.append("\n\n  <div class=\"align-center center avatar__form gap\" data-controller=\"upload-preview\">\n    ");
    let file_field = "<input id=\"file\" class=\"input\" accept=\"image/*\" data-upload-preview-target=\"input\" data-action=\"upload-preview#previewImage change-&gt;form#submit\" type=\"file\" name=\"user[avatar]\" />";
    profile_form_start(out,"txt-medium",true);
    out.append("      <label class=\"btn input--file\">\n        "); out.append(image_html("camera.svg",[html_attr("aria-hidden","true"),html_attr("size",20)]));
    out.append("\n        "); out.append(file_field); out.append("\n        <span class=\"for-screen-reader\">Upload avatar</span>\n      </label>\n</form>\n    ");
    profile_form_start(out,"",true);
    out.append("      <label class=\"btn avatar input--file txt-xx-large\">\n        <img aria-hidden=\"true\" data-upload-preview-target=\"image\" src=\"");
    escape(out,ctx.user.avatar_url); out.append("\" width=\"300\" height=\"300\" />\n        "); out.append(file_field);
    out.append("\n        <span class=\"for-screen-reader\">Avatar</span>\n      </label>\n</form>\n");
    if sql_number(db,"SELECT count(*) FROM active_storage_attachments WHERE record_type='User' AND name='avatar' AND record_id=?",[sql_text(user)]) > 0 {
        format(out,"\n      <form class=\"button_to\" method=\"post\" action=\"/users/",user,"/avatar\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn btn--negative txt-small avatar__delete-btn\" type=\"submit\">\n        ");
        out.append(image_html("minus.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n        <span class=\"for-screen-reader\">Delete avatar</span>\n</button></form>\n");
    }
    out.append("  </div>\n\n  "); profile_form_start(out,"",false); out.append("    <div class=\"flex flex-column gap\">\n");
    var field: u8[>..] = [];
    field.append("<input class=\"input txt-large \" autocomplete=\"name\" placeholder=\"Enter your name\" autofocus=\"autofocus\" required=\"required\" data-1p-ignore=\"true\" type=\"text\" value=\"");
    escape(field,name); field.append("\" name=\"user[name]\" id=\"user_name\" />");
    profile_field(out,ctx,"user_name","align-center","flex align-center gap flex-item-grow input input--actor",field,"person.svg");
    field.clear(); field.append("<input class=\"input txt-large\" ");
    if has_email { field.append("value=\""); escape(field,email); field.append("\" "); }
    field.append("autocomplete=\"username\" placeholder=\"Enter your email address\" type=\"email\" name=\"user[email_address]\" id=\"user_email_address\" />");
    profile_field(out,ctx,"email_address","align-center","flex align-center gap flex-item-grow input input--actor",field,"email.svg");
    profile_field(out,ctx,"update_password","align-center","flex align-center gap flex-item-grow input input--actor",
        "<input class=\"input txt-large\" autocomplete=\"new-password\" placeholder=\"Change password\" maxlength=\"72\" size=\"72\" type=\"password\" name=\"user[password]\" id=\"user_password\" />","password.svg");
    field.clear(); field.append("<textarea class=\"input txt-large\" placeholder=\"A few words about yourself…\" maxlength=\"200\" rows=\"3\" name=\"user[bio]\" id=\"user_bio\">\n");
    escape(field,bio); field.append("</textarea>");
    profile_field(out,ctx,"bio","align-start","flex align--center gap flex-item--grow input input--actor",field,"bio.svg");
    out.append("      "); submit_button(out); out.append("    </div>\n</form>\n");

    // Current.user.memberships.with_ordered_room, shared rooms first.
    out.append("  <div class=\"margin-block pad-inline pad-block fill-shade border-radius\">\n    <menu class=\"flex flex-column gap margin-none pad\">\n");
    let memberships = sql_rows(db,"SELECT r.id,r.type,COALESCE(r.name,''),COALESCE(m.involvement,'mentions') FROM memberships m JOIN rooms r ON r.id=m.room_id WHERE m.user_id=? ORDER BY LOWER(r.name)",[sql_text(user)]);
    var shared = 0; var directs = 0;
    for row in memberships { if cell(row,1) == "Rooms::Direct" { directs += 1; } else { shared += 1; } }
    for pass in 2 {
        if pass == 1 && shared > 0 && directs > 0 { out.append("\n        <hr class=\"separator full-width\" style=\"--border-style: solid\">\n\n"); }
        for row in memberships {
            let direct = cell(row,1) == "Rooms::Direct";
            if direct != (pass == 1) { continue; }
            let room, valid = parse_int(cell(row,0));
            let involvement = cell(row,3);
            let known: u8[>..] = if involvement_known(involvement) { str(involvement) } else { str("mentions") };
            if direct {
                let others = direct_room_name(db,room,user);
                membership_html(out,room,cell(row,1),if others.len > 0 { others } else { name },known);
            } else { membership_html(out,room,cell(row,1),cell(row,2),known); }
        }
    }
    out.append("    </menu>\n  </div>\n\n  ");
    transfer_html(out,transfer_url(db,req,user,avatar_key),true);
    out.append("\n</section>\n");
    return out;
}

// accounts/_invite
fn invite_html(out: u8[>..]&, url: const u8[:], admin: bool) {
    out.append("<div class=\"flex flex-column align-center gap\">\n\n  <label class=\"flex flex-column gap full-width\" style=\"--row-gap: 0.5em\">\n    <strong id=\"invite_label\" class=\"invite-label\">Share to invite more people</strong>\n    <span class=\"flex align-center gap input input--actor fill-white\">\n      ");
    out.append(image_html("person-add.svg",[html_attr("aria-hidden","true"),html_attr("size",20),html_attr("class","colorize--black")]));
    out.append("\n      <input type=\"text\" class=\"input\" id=\"invite_url\" value=\""); escape(out,url); out.append("\" aria-labelledby=\"invite_label\" readonly>\n    </span>\n  </label>\n\n  <div class=\"flex align-center gap\">\n    ");
    out.append(zoom_qr_link(url,"Show join link QR code")); out.append("\n    ");
    out.append(block_button_to_copy_to_clipboard(url,icon_body("Copy join link","copy-paste.svg","colorize--black"))); out.append("\n    ");
    out.append(block_web_share_session_button(url,"Link to join Campfire","Hit this link to join me in Campfire and start chatting.",icon_body("Share join link","share.svg","colorize--black")));
    if admin {
        out.append("\n      <form class=\"button_to\" method=\"post\" action=\"/account/join_code\"><button class=\"btn btn--regenerate\" type=\"submit\">\n        ");
        out.append(image_html("refresh.svg",[html_attr("aria-hidden","true"),html_attr("size",20),html_attr("class","colorize--black")]));
        out.append("\n        <span class=\"for-screen-reader\">Regenerate join link</span>\n</button></form>");
    }
    out.append("  </div>\n</div>\n");
}

fn logo_form(out: u8[>..]&, classes: const u8[:], label: const u8[:], image: const u8[:]) {
    out.append("<form "); if classes.len > 0 { out.append("class=\""); out.append(classes); out.append("\" "); }
    out.append("data-controller=\"form\" enctype=\"multipart/form-data\" action=\"/account.1\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\" />\n        <label class=\"");
    out.append(label); out.append("\">\n          "); out.append(image);
    out.append("\n          <input class=\"input\" accept=\"image/*\" data-action=\"upload-preview#previewImage change-&gt;form#submit\" type=\"file\" name=\"account[logo]\" id=\"account_logo\" />\n          <span class=\"for-screen-reader\">Upload logo</span>\n        </label>\n</form>");
}

// accounts/edit
fn account_page(db, ctx: ViewContext&, bytes: u8[>..]&, req: const http::Request&, user: i64, avatar_key: const u8[:]) -> u8[>..] {
    let admin = ctx.user.administrator;
    ctx.title = "Account settings";
    var nav = back_nav(last_room_path(db,user,req));
    if admin {
        nav.append("\n    <div class=\"flex align-center gap flex-item-justify-end\">\n      <a class=\"btn\" style=\"view-transition-name: chat-bots\" href=\"/account/bots\">\n        ");
        nav.append(image_html("bot.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); nav.append("\n        <span class=\"for-screen-reader\">Set up chat bots</span>\n</a>\n");
        nav.append("      <a class=\"btn\" style=\"view-transition-name: custom-styles\" href=\"/account/custom_styles/edit\">\n        ");
        nav.append(image_html("art.svg",[html_attr("size",20),html_attr("aria-hidden","true")])); nav.append("\n        <span class=\"for-screen-reader\">Custom styles</span>\n</a>    </div>\n");
    }
    ctx.page_nav = view_keep(bytes,nav);
    ctx.page_footer = view_keep(bytes,version_footer());
    let account = sql_rows(db,"SELECT name,join_code,json_extract(settings,'$.restrict_room_creation_to_administrators') FROM accounts ORDER BY id LIMIT 1",[]);
    let name = rows_col(account,0,0); let restricted = rows_col(account,0,2) != "" && rows_col(account,0,2) != "0";
    var out: u8[>..] = [];
    out.append("\n<section class=\"panel txt-align-center flex flex-column gap\" style=\"view-transition-name: account-settings\">\n");
    if admin {
        out.append("    <div class=\"align-center center avatar__form gap\" data-controller=\"upload-preview\">\n      ");
        logo_form(out,"txt--medium","btn input--file",image_html("camera.svg",[html_attr("aria-hidden","true"),html_attr("size",20)]));
        out.append("\n      ");
        var image: u8[>..] = []; image.append("<img role=\"presentation\" data-upload-preview-target=\"image\" src=\""); escape(image,ctx.account.logo_url); image.append("\" width=\"48\" height=\"48\" />");
        logo_form(out,"","btn avatar input--file account-logo txt-xx-large",image);
        if ctx.account.has_logo {
            out.append("\n        <form class=\"button_to\" method=\"post\" action=\""); escape(out,ctx.account.logo_url);
            out.append("\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn btn--negative txt-small avatar__delete-btn\" type=\"submit\">\n          ");
            out.append(image_html("minus.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n          <span class=\"for-screen-reader\">Delete logo</span>\n</button></form>");
        }
        out.append("\n    </div>\n\n    <form class=\"flex flex-column gap\" data-controller=\"form\" action=\"/account.1\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\" />\n      <div class=\"flex align-center gap\">\n        ");
        out.append(translation_button_html(ctx,"account_name"));
        out.append("\n\n        <label class=\"flex align-center gap flex-item-grow\">\n          <input class=\"input txt-large\" autocomplete=\"off\" placeholder=\"Name this account\" autofocus=\"autofocus\" data-action=\"keydown.enter-&gt;form#submit\" type=\"text\" value=\"");
        escape(out,name); out.append("\" name=\"account[name]\" id=\"account_name\" />\n        </label>\n\n        <button name=\"button\" type=\"submit\" class=\"btn btn--reversed center\">\n          ");
        out.append(image_html("check.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n          <span class=\"for-screen-reader\">Save changes</span>\n</button>      </div>\n</form>\n");
        out.append("    <div class=\"margin-block-start pad-block pad-inline-double fill-shade border-radius\">\n      <form class=\"flex align-center gap center\" data-controller=\"form\" action=\"/account.1\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"put\" />\n        <div class=\"flex-item-grow flex align-center gap txt-align-start\">\n          ");
        out.append(image_html("crown.svg",[html_attr("class","colorize--black"),html_attr("aria-hidden","true"),html_attr("size",18)]));
        out.append(" Must be admin to create new rooms\n        </div>\n        \n          <input value=\""); out.append(if restricted { "false" } else { "true" });
        out.append("\" type=\"hidden\" name=\"account[settings][restrict_room_creation_to_administrators]\" id=\"account_settings_restrict_room_creation_to_administrators\" />\n\n        <label class=\"switch\">\n          <input type=\"checkbox\"\n                class=\"switch__input\"\n                ");
        if restricted { out.append("checked"); }
        out.append("\n                data-action=\"change->form#submit\">\n          <span class=\"switch__btn round\"></span>\n          <span class=\"for-screen-reader\">\n            Must be admin to create new rooms\n          </span>\n        </label>\n\n</form>    </div>\n");
    } else {
        out.append("    "); out.append(account_logo_html(ctx,"txt-xx-large center"));
        out.append("\n    <h1 class=\"flex-item-grow txt-x-large\">"); escape(out,name); out.append("</h1>\n");
    }
    out.append("\n  <div class=\"margin-block pad-inline pad-block-start fill-shade border-radius\">\n    ");
    invite_html(out,str(request_base(req),"/join/",rows_col(account,0,1)),admin);
    out.append("\n\n    <hr class=\"margin-block separator full-width\" style=\"--border-style: solid\">\n\n    <menu class=\"flex flex-column gap margin-none pad\">\n      <turbo-frame id=\"account_users\">\n");
    // AccountsController#edit: every user in the partitions, and the next page's frame past 500.
    let users = sql_rows(db,str(USER_COLUMNS,"WHERE status IN (0",if admin { ",2" } else { "" },") AND role<>2 ORDER BY LOWER(name)"),[]);
    var administrators = 0; var members = 0;
    for row in users { if cell(row,4) == "1" { administrators += 1; } else { members += 1; } }
    for pass in 2 {
        if pass == 1 && administrators > 0 && members > 0 { out.append("\n          <hr class=\"separator full-width\" style=\"--border-style: solid\">\n\n"); }
        for row in users { if (cell(row,4) == "1") == (pass == 0) { account_user_html(out,row,user,admin,avatar_key); } }
    }
    if users.len > 500 { next_page_html(out,2); }
    out.append("      </turbo-frame>\n    </menu>\n  </div>\n</section>\n");
    return out;
}

// accounts/custom_styles/edit
fn custom_styles_page(db, ctx: ViewContext&, bytes: u8[>..]&, req: const http::Request&) -> u8[>..] {
    ctx.title = "Custom styles";
    ctx.page_nav = view_keep(bytes,back_nav("/account/edit"));
    var out: u8[>..] = [];
    out.append("\n<section class=\"panel panel--wide txt-align-center flex flex-column position-relative\" style=\"view-transition-name: custom-styles\">\n  <form class=\"flex flex-column gap\" data-controller=\"form\" data-action=\"keydown.ctrl+enter-&gt;form#submit keydown.meta+enter-&gt;form#submit\" action=\"");
    escape(out,request_base(req)); out.append("/account/custom_styles\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\" />\n    <div class=\"panel__button\">\n      ");
    out.append(translation_button_html(ctx,"custom_styles"));
    out.append("\n    </div>\n\n    <div class=\"pad-inline-double margin-inline\">\n      <h1 class=\"margin-none\">Custom CSS</h1>\n      <p class=\"flex flex-wrap align-center justify-center gap margin-none-block-start\" style=\"--column-gap: 0.5ch; --row-gap: 0\">\n        <span>Add custom CSS styles.</span>\n        ");
    out.append(image_html("alert.svg",[html_attr("class","flex-inline colorize--black"),html_attr("size",16),html_attr("aria-hidden","true")]));
    out.append("\n        <span>Use Caution: you could break things.</span>\n      </p>\n    </div>\n\n    <label class=\"flex align-start gap flex-item-grow\">\n      <textarea class=\"input input--code txt--small\" placeholder=\"Add CSS styles…\" autocomplete=\"off\" spellcheck=\"false\" autocorrect=\"off\" autocapitalize=\"off\" rows=\"16\" name=\"account[custom_styles]\" id=\"account_custom_styles\">\n");
    escape(out,ctx.custom_styles);
    out.append("</textarea>\n    </label>\n\n    <button name=\"button\" type=\"submit\" class=\"btn btn--reversed center txt-large\">\n      ");
    out.append(image_html("check.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n      <span class=\"for-screen-reader\">Save changes</span>\n</button></form></section>\n");
    return out;
}

fn copy_line(out: u8[>..]&, icon: const u8[:], line: const u8[:], label: const u8[:], copy_label: const u8[:]) {
    out.append("\n      <div class=\"flex align-center gap\">\n        ");
    out.append(image_html(icon,[html_attr("aria-hidden","true"),html_attr("size",24),html_attr("class","colorize--black")]));
    out.append("\n\n        <div class=\"flex-item-grow\">\n          <input type=\"text\" class=\"input full-width fill-white\" value=\""); escape(out,line);
    out.append("\" aria-label=\""); out.append(label); out.append("\" readonly>\n        </div>\n\n        <div class=\"txt-small\">\n          ");
    var body: u8[>..] = []; body.append("\n            "); body.append(image_html("copy-paste.svg",[html_attr("aria-hidden","true"),html_attr("size",20)]));
    body.append("\n            <span class=\"for-screen-reader\">"); body.append(copy_label); body.append("</span>\n");
    out.append(block_button_to_copy_to_clipboard(line,body)); out.append("        </div>\n      </div>\n");
}

// accounts/bots/index with accounts/bots/_bot
fn bots_page(db, ctx: ViewContext&, bytes: u8[>..]&, req: const http::Request&, avatar_key: const u8[:]) -> u8[>..] {
    ctx.title = "Chat bots";
    ctx.page_nav = view_keep(bytes,back_nav("/account/edit"));
    var out: u8[>..] = [];
    out.append("\n<section class=\"panel panel--wide txt-align-center flex flex-column position-relative\" style=\"view-transition-name: chat-bots\">\n  <div class=\"flex align-center gap\">\n    <div class=\"panel__button\">\n      ");
    out.append(translation_button_html(ctx,"chat_bots"));
    out.append("\n    </div>\n    <div class=\"pad-inline-double center\">\n      <h1 class=\"margin-none\">Chat bots</h1>\n      <p class=\"margin-none-block-start\">With Chat bots, other sites and services can post updates directly to Campfire.</p>\n\n      <a class=\"btn btn--reversed txt-large\" aria-label=\"Add a chat bot\" href=\"/account/bots/new\">\n        ");
    out.append(image_html("bot.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n        ");
    out.append(image_html("add.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n</a>    </div>\n  </div>\n\n  <div class=\"pad-inline pad-block-start \">\n    <menu class=\"flex flex-column gap margin-none pad\">\n      ");
    for bot in sql_rows(db,"SELECT id,bot_token FROM users WHERE status=0 AND role=2 ORDER BY LOWER(name)",[]) {
        let id, valid = parse_int(cell(bot,0)); let person = load_user(db,id,avatar_key,bytes);
        format(out,"<li class=\"flex flex-column gap flush fill-shade border-radius pad-block pad-inline-double\">\n  <div class=\"flex align-center gap\">\n    <figure class=\"avatar flex-item--no-shrink\" style=\"--avatar-size: 2.65em;\">\n      <a title=\"");
        escape(out,person.title); out.append("\" class=\"btn avatar\" data-turbo-frame=\"_top\" href=\""); escape(out,person.path);
        out.append("\"><img aria-hidden=\"true\" loading=\"lazy\" src=\""); escape(out,person.avatar_url);
        out.append("\" width=\"48\" height=\"48\" /></a>\n    </figure>\n\n    <div class=\"min-width\">\n      <div class=\"overflow-ellipsis txt-large\"><strong>"); escape(out,person.name);
        format(out,"</strong></div>\n    </div>\n\n    <a class=\"btn flex-item-justify-end\" style=\"view-transition-name: chat-bot-",id,"\" href=\"/account/bots/",id,"/edit\">\n      ");
        out.append(image_html("pencil.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n      <span class=\"for-screen-reader\">Edit "); escape(out,person.name); out.append("</span>\n</a>  </div>\n\n");
        // bot.rooms.without_directs.ordered
        for room in sql_rows(db,"SELECT r.id,COALESCE(r.name,'') FROM rooms r JOIN memberships m ON m.room_id=r.id WHERE m.user_id=? AND r.type<>'Rooms::Direct' ORDER BY LOWER(r.name)",[sql_text(id)]) {
            out.append("    <fieldset class=\"gap max-width pad border border-radius\">\n      <legend class=\"min-width txt-align-start pad-inline\">\n        <strong class=\"overflow-ellipsis\">");
            escape(out,cell(room,1)); out.append("</strong>\n      </legend>\n");
            let url = str(request_base(req),"/rooms/",cell(room,0),"/",id,"-",cell(bot,1),"/messages");
            copy_line(out,"messages-outlined.svg",str("curl -d 'Hello!' ",url),"curl command for posting messages","Copy message command");
            copy_line(out,"attachment.svg",str("curl -F \"attachment=@/path/to/file\" ",url),"curl command for posting attachments","Copy attachment command");
            out.append("    </fieldset>\n");
        }
        out.append("</li>\n");
    }
    out.append("\n    </menu>\n  </div>\n</section>\n");
    return out;
}

// accounts/bots/_form, in new or edit; bot is 0 for a new one.
fn bot_page(db, ctx: ViewContext&, bytes: u8[>..]&, req: const http::Request&, bot: i64, storage_key: const u8[:]) -> u8[>..] {
    ctx.title = if bot == 0 { "New chat bot" } else { "Edit bot" };
    ctx.page_nav = view_keep(bytes,back_nav("/account/bots"));
    var name: u8[>..] = []; var webhook: u8[>..] = []; var has_name = false; var has_webhook = false; var avatar: u8[>..] = [];
    if bot > 0 {
        for row in sql_rows(db,"SELECT name,(SELECT url FROM webhooks WHERE user_id=users.id ORDER BY id LIMIT 1),(SELECT count(*) FROM webhooks WHERE user_id=users.id AND url IS NOT NULL) FROM users WHERE id=?",[sql_text(bot)]) {
            name = str(cell(row,0)); has_name = true; webhook = str(cell(row,1)); has_webhook = cell(row,2) != "0";
        }
        for row in sql_rows(db,"SELECT b.id,b.filename FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='User' AND a.name='avatar' AND a.record_id=? ORDER BY a.id DESC LIMIT 1",[sql_text(bot)]) {
            // image_tag of an attachment: its absolute URL.
            let blob, valid = parse_int(cell(row,0)); avatar = str(request_base(req),blob_redirect_path(blob,cell(row,1),"",storage_key));
        }
    }
    var out: u8[>..] = [];
    if bot == 0 { out.append("\n<section class=\"panel\">\n  <form class=\"flex flex-column gap\" enctype=\"multipart/form-data\" action=\"/account/bots\" accept-charset=\"UTF-8\" method=\"post\">\n"); }
    else { format(out,"\n<section class=\"panel\" style=\"view-transition-name: chat-bot-",bot,"\">\n  <form class=\"flex flex-column gap\" enctype=\"multipart/form-data\" action=\"/account/bots/",bot,"\" accept-charset=\"UTF-8\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\" />\n"); }
    out.append("    <h1 class=\"for-screen-reader\">Chat Bot Setup</h1>\n<label class=\"align-center center avatar__form gap\" data-controller=\"upload-preview\">\n  <div class=\"btn input--file\">\n    ");
    out.append(image_html("camera.svg",[html_attr("aria-hidden","true"),html_attr("size",20)]));
    out.append("\n    <input class=\"input\" accept=\"image/*\" data-upload-preview-target=\"input\" data-action=\"upload-preview#previewImage\" type=\"file\" name=\"user[avatar]\" id=\"user_avatar\" />\n    <span class=\"for-screen-reader\">Upload bot avatar</span>\n  </div>\n\n  <div class=\"avatar input--file txt-xx-large\" style=\"--avatar-size: var(--btn-size);\">\n    ");
    if avatar.len > 0 { out.append("<img alt=\"Bot avatar\" data-upload-preview-target=\"image\" src=\""); escape(out,avatar); out.append("\" width=\"48\" height=\"48\" />"); }
    else { out.append(image_html("default-bot-avatar.svg",[html_attr("alt","Bot avatar"),html_attr("size",48),html_attr("data-upload-preview-target","image")])); }
    out.append("\n  </div>\n</label>\n\n<div class=\"flex align-center gap\">\n  "); out.append(translation_button_html(ctx,"bot_name"));
    out.append("\n  <label class=\"flex align-center gap flex-item-grow txt-large input input--actor\">\n    <input class=\"input\" autocomplete=\"name\" placeholder=\"Name the bot\" autofocus=\"autofocus\" required=\"required\" data-1p-ignore=\"true\" type=\"text\" ");
    if has_name { out.append("value=\""); escape(out,name); out.append("\" "); }
    out.append("name=\"user[name]\" id=\"user_name\" />\n    "); out.append(image_html("bot.svg",[html_attr("aria-hidden","true"),html_attr("size",24),html_attr("class","colorize--black")]));
    out.append("\n  </label>\n</div>\n\n<div class=\"flex align-center gap\">\n  "); out.append(translation_button_html(ctx,"webhook_url"));
    out.append("\n  <label class=\"flex align-center gap flex-item-grow txt-large input input--actor\">\n    <input class=\"input\" placeholder=\"Webhook URL\" type=\"url\" ");
    if has_webhook { out.append("value=\""); escape(out,webhook); out.append("\" "); }
    out.append("name=\"user[webhook_url]\" id=\"user_webhook_url\" />\n    "); out.append(image_html("web.svg",[html_attr("aria-hidden","true"),html_attr("size",24),html_attr("class","colorize--black")]));
    out.append("\n  </label>\n</div>\n\n"); submit_button(out); out.append("\n</form>");
    if bot > 0 {
        format(out,"\n  <hr class=\"separator full-width margin-block-double\">\n\n  <div class=\"flex align-center gap justify-space-between\">\n    <form class=\"button_to\" method=\"post\" action=\"/account/bots/",bot,"\"><input type=\"hidden\" name=\"_method\" value=\"delete\" /><button class=\"btn txt--small btn--negative\" aria-label=\"Delete this chat bot\" data-turbo-confirm=\"Are you sure you want to permanently remove this bot from the account? This can’t be undone.\" type=\"submit\">\n      ");
        out.append(image_html("trash.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n      ");
        out.append(image_html("bot.svg",[html_attr("aria-hidden","true"),html_attr("size",20)]));
        format(out,"\n</button></form>\n    <form class=\"button_to\" method=\"post\" action=\"/account/bots/",bot,"/key\"><input type=\"hidden\" name=\"_method\" value=\"put\" /><button class=\"btn full-width txt--small btn--negative\" aria-label=\"Generate a new key\" data-turbo-confirm=\"Are you sure you want to change the bot key? All usage of this bot must be updated.\" type=\"submit\">\n      ");
        out.append(image_html("refresh.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n      ");
        out.append(image_html("key.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); out.append("\n</button></form>  </div>\n");
    }
    out.append("</section>\n");
    return out;
}

// A user[field] parameter saved, touching the user only when it changes.
fn update_user_field(db, req: const http::Request&, body: const u8[:], user: i64, now: const u8[:], field: const u8[:]) {
    var value: u8[>..] = [];
    if param_of(req,body,str("user[",field,"]"),value) {
        sql_rows(db,str("UPDATE users SET ",field,"=?,updated_at=? WHERE id=? AND ",field," IS NOT ?"),[sql_text(value),sql_text(now),sql_text(user),sql_text(value)]);
    }
}

// --- Routing -------------------------------------------------------------------------------------

let ACCOUNT_PROFILE: i32 = 1;
let ACCOUNT_SETTINGS: i32 = 2;
let ACCOUNT_EDIT: i32 = 3;
let ACCOUNT_STYLES: i32 = 4;
let ACCOUNT_STYLES_EDIT: i32 = 5;
let ACCOUNT_BOTS: i32 = 6;
let ACCOUNT_BOT_NEW: i32 = 7;
let ACCOUNT_BOT: i32 = 8;
let ACCOUNT_BOT_EDIT: i32 = 9;
let ACCOUNT_BOT_KEY: i32 = 10;
let ACCOUNT_UNROUTED: i32 = 11;
let ACCOUNT_PUSH: i32 = 12;

// QrCodeController#show, which needs no session: the SVG of the URL-safe Base64 id.
fn qr_code_route(req: const http::Request&, out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    guard starts_with(path,"/qr_code/") else { return false; }
    var id = path[9..];
    // A dot starts the route's format.
    let dot = find(id,"."); if dot >= 0 { id = id[..dot]; }
    if id.len == 0 || find(id,"/") >= 0 || (req.method != "GET" && req.method != "HEAD") { http::respond(out,404,"text/plain","Not found"); return true; }
    var raw: u8[>..] = []; var text: u8[>..] = []; var svg: u8[>..] = [];
    // Base64.urlsafe_decode64, which pads an unpadded id.
    guard http::decode(id,raw,false) && base64_url_decode(text,raw) && qr_svg(text,svg) else {
        http::respond(out,500,"text/plain","Unable to draw the QR code"); return true;
    }
    http::start(out,200);
    http::field(out,"Cache-Control","max-age=31556952, public");
    http::field(out,"Content-Type","image/svg+xml; charset=utf-8");
    http::finish(out,http::NO_TYPE,svg);
    return true;
}

fn account_kind(path: const u8[:], id: i64&) -> i32 {
    if starts_with(path,"/users/") {
        let rest = path[7..]; let slash = find(rest,"/");
        if slash <= 0 { return 0; }
        let tail = rest[slash..];
        if tail == "/profile" { return ACCOUNT_PROFILE; }
        if tail == "/profile/edit" || tail == "/profile/new" { return ACCOUNT_UNROUTED; }
        if tail == "/push_subscriptions" { return ACCOUNT_PUSH; }
        return 0;
    }
    if path == "/account" || starts_with(path,"/account.") { return ACCOUNT_SETTINGS; }
    if path == "/account/edit" { return ACCOUNT_EDIT; }
    if path == "/account/new" { return ACCOUNT_UNROUTED; }
    if path == "/account/custom_styles" { return ACCOUNT_STYLES; }
    if path == "/account/custom_styles/edit" { return ACCOUNT_STYLES_EDIT; }
    if path == "/account/bots" { return ACCOUNT_BOTS; }
    if path == "/account/bots/new" { return ACCOUNT_BOT_NEW; }
    if starts_with(path,"/account/bots/") {
        let rest = path[14..]; let slash = find(rest,"/");
        let n, valid = parse_int(if slash < 0 { rest } else { rest[..slash] });
        id = if valid { n } else { -1 };
        if slash < 0 { return ACCOUNT_BOT; }
        if rest[slash..] == "/edit" { return ACCOUNT_BOT_EDIT; }
        if rest[slash..] == "/key" { return ACCOUNT_BOT_KEY; }
        return ACCOUNT_UNROUTED;
    }
    return 0;
}

// Rack::MethodOverride: a POST's _method, from a urlencoded or a multipart form.
fn request_method(req: const http::Request&, body: const u8[:]) -> u8[>..] {
    if req.method == "POST" && content_type_is(req,"multipart/form-data") {
        let value, fields, found = http::find_part(req,body,"_method");
        if found == http::PART_FOUND {
            let lower = html_lower(value);
            if lower == "patch" { return str("PATCH"); } else if lower == "put" { return str("PUT"); } else if lower == "delete" { return str("DELETE"); }
        }
        return str(req.method);
    }
    return effective_method(req,body);
}

// Profile, account settings, custom styles and bots; false for any other path.
fn account_route(db: sqlite::Db, user: i64, req: const http::Request&, body: const u8[:], avatar_key: const u8[:], stream_key: const u8[:],
                 vapid: const u8[:], storage_key: const u8[:], storage: const u8[:], cookie_key: const u8[:], out: http::Reply) -> bool {
    let path = http::path_of(req.target);
    var id: i64 = 0;
    let kind = account_kind(path,id);
    guard kind > 0 else { return false; }
    let method = request_method(req,body);
    let reading = method == "GET" || method == "HEAD";
    let updating = method == "PATCH" || method == "PUT";
    // Users::PushSubscriptionsController's other actions are admin_route's.
    if kind == ACCOUNT_PUSH && !reading { return false; }
    // The routes Rails draws for each, the others being 404s (resource routes without their actions among them).
    let routed = if kind == ACCOUNT_PROFILE || kind == ACCOUNT_SETTINGS || kind == ACCOUNT_STYLES { reading && kind == ACCOUNT_PROFILE || updating }
        else if kind == ACCOUNT_EDIT || kind == ACCOUNT_PUSH || kind == ACCOUNT_STYLES_EDIT || kind == ACCOUNT_BOT_NEW || kind == ACCOUNT_BOT_EDIT { reading }
        else if kind == ACCOUNT_BOTS { reading || method == "POST" }
        else if kind == ACCOUNT_BOT { updating || method == "DELETE" }
        else if kind == ACCOUNT_BOT_KEY { updating } else { false };
    if !routed { http::respond(out,404,"text/plain","Not found"); return true; }
    if !reading && !same_origin(req) { http::respond(out,422,"text/plain","Invalid origin"); return true; }

    if reading {
        var status: i32 = 200; var bytes: u8[>..] = []; var content: u8[>..] = []; var ctx = ViewContext { .. };
        let failed = sqlite::run() {
            ctx = load_view_context(db,user,avatar_key,stream_key,vapid,req,bytes,storage_key);
            let admin = ctx.user.administrator;
            if kind == ACCOUNT_PROFILE { content = profile_page(db,ctx,bytes,req,user,avatar_key); }
            else if kind == ACCOUNT_EDIT { content = account_page(db,ctx,bytes,req,user,avatar_key); }
            else if kind == ACCOUNT_PUSH {
                // users/push_subscriptions/index
                ctx.title = "Push notification subscriptions";
                ctx.page_nav = view_keep(bytes,back_nav(last_room_path(db,user,req)));
                content.append("\n"); push_subscriptions_html(db,user,content);
            }
            else if !admin { status = 403; }
            else if kind == ACCOUNT_STYLES_EDIT { content = custom_styles_page(db,ctx,bytes,req); }
            else if kind == ACCOUNT_BOTS { content = bots_page(db,ctx,bytes,req,avatar_key); }
            else if kind == ACCOUNT_BOT_NEW { content = bot_page(db,ctx,bytes,req,0,storage_key); }
            else if sql_number(db,"SELECT count(*) FROM users WHERE id=? AND role=2 AND status=0",[sql_text(id)]) == 0 { status = 404; }
            else { content = bot_page(db,ctx,bytes,req,id,storage_key); }
        };
        if failed.len > 0 { for e in failed { write_stderr(str("account page failed: ",e.message,"\n")); } http::respond(out,500,"text/plain","Database error"); }
        else if status == 403 { respond_empty(out,403); }
        else if status == 404 { http::respond(out,404,"text/plain","Not found"); }
        else { ctx.page_content = content; respond_with_flash(out,req,ctx,bytes,cookie_key); }
        return true;
    }

    var status: i32 = 302; var location: u8[>..] = []; var notice: u8[>..] = [];
    var keys: u8[][>..] = []; var written: u8[>..] = []; var avatar: i64 = 0; var avatar_user: i64 = 0; var logo: i64 = 0;
    // A video or audio avatar is analyzed with ffprobe instead (AnalyzeJob).
    var probed: i64 = 0;
    // A deactivated bot's connections close once the transaction commits.
    var changes: i64[>..] = [];
    var upload = Upload { .. };
    var now: u8[>..] = []; campfire_sql_now(now);
    // A file part is written before the transaction, and removed again unless it commits.
    let file_field = if kind == ACCOUNT_PROFILE || kind == ACCOUNT_BOTS || kind == ACCOUNT_BOT { "user[avatar]" } else { "" };
    let staged = if file_field.len > 0 { staged_file(req,body,file_field,storage,upload) } else { 0 };
    if staged == 1 { written.append(upload.key); }
    if staged == 400 || staged == 500 { http::respond(out,staged,"text/plain","Unable to store the file"); return true; }
    var digest: u8[>..] = [];
    if kind == ACCOUNT_PROFILE {
        // has_secure_password: a blank password changes nothing; bcrypt reads only its first 72 bytes.
        var password: u8[>..] = [];
        if param_of(req,body,"user[password]",password) && password.len > 0 {
            var entropy: u8[16] = [0;16]; hash::random_bytes(entropy);
            if !campfire_password_hash(password[..min(password.len,72)],entropy,digest) { http::respond(out,500,"text/plain","Unable to set the password"); if written.len > 0 { delete_blob_file(storage,written); } return true; }
        }
    }
    let failed = write_access_transaction(db,changes) {
        let admin = sql_number(db,"SELECT role FROM users WHERE id=? AND status=0",[sql_text(user)]) == 1;
        var value: u8[>..] = [];
        if kind == ACCOUNT_PROFILE {
            // Users::ProfilesController#update: params.require(:user).permit(:name, :avatar, :email_address, :password, :bio)
            if !has_params(req,body,"user[",["user[name]","user[avatar]","user[email_address]","user[password]","user[bio]"]) { status = 400; }
            else {
                update_user_field(db,req,body,user,now,"name");
                update_user_field(db,req,body,user,now,"email_address");
                update_user_field(db,req,body,user,now,"bio");
                if digest.len > 0 { sql_rows(db,"UPDATE users SET password_digest=?,updated_at=? WHERE id=?",[sql_text(digest),sql_text(now),sql_text(user)]); }
                var avatar_given = staged == 1;
                if staged == 1 {
                    // has_one_attached replaces the avatar, purging the old one; the attachment touches the user.
                    purge_attachments(db,"record_type='User' AND name='avatar' AND record_id=?",[sql_text(user)],keys);
                    let blob = save_upload(db,upload,"avatar","User",user,now);
                    if variable_content_type(upload.content_type) { avatar = blob; avatar_user = user; }
                    if probed_content_type(upload.content_type) { probed = blob; }
                    sql_rows(db,"UPDATE users SET updated_at=? WHERE id=?",[sql_text(now),sql_text(user)]);
                } else if !content_type_is(req,"multipart/form-data") && param_of(req,body,"user[avatar]",value) { avatar_given = true; }
                location = str("/users/me/profile");
                notice = str(if avatar_given { "It may take up to 30 minutes to change everywhere." } else { "✓" });
            }
        } else if kind == ACCOUNT_SETTINGS || kind == ACCOUNT_STYLES {
            let styles = kind == ACCOUNT_STYLES;
            if !admin { status = 403; }
            else if styles {
                // Accounts::CustomStylesController#update: params.require(:account).permit(:custom_styles)
                if !has_params(req,body,"account[",["account[custom_styles]"]) { status = 400; }
                else {
                    if param_of(req,body,"account[custom_styles]",value) { sql_rows(db,"UPDATE accounts SET custom_styles=?,updated_at=? WHERE custom_styles IS NOT ?",[sql_text(value),sql_text(now),sql_text(value)]); }
                    sql_rows(db,SETTINGS_DEFAULTS,[]);
                    location = str("/account/custom_styles/edit"); notice = str("✓");
                }
            } else if !has_params(req,body,"account[",["account[name]","account[logo]","account[settings][restrict_room_creation_to_administrators]"]) { status = 400; }
            else {
                // AccountsController#update: params.require(:account).permit(:name, :logo, settings: {}). Settings outside
                // has_json's schema raise NoMethodError.
                if !content_type_is(req,"multipart/form-data") {
                    for field in split(body,"&") {
                        let eq = find(field,"="); var key: u8[>..] = [];
                        if http::decode(if eq < 0 { field } else { field[..eq] },key,true) && starts_with(key,"account[settings][") && key != "account[settings][restrict_room_creation_to_administrators]" { status = 500; }
                    }
                }
                if status == 302 {
                    if param_of(req,body,"account[name]",value) { sql_rows(db,"UPDATE accounts SET name=?,updated_at=? WHERE name IS NOT ?",[sql_text(value),sql_text(now),sql_text(value)]); }
                    if param_of(req,body,"account[settings][restrict_room_creation_to_administrators]",value) {
                        let cast = boolean_json(value);
                        sql_rows(db,"UPDATE accounts SET settings=json_set(COALESCE(settings,'{}'),'$.restrict_room_creation_to_administrators',json(?)),updated_at=? WHERE json_type(COALESCE(settings,'{}'),'$.restrict_room_creation_to_administrators') IS NOT ? OR json_type(COALESCE(settings,'{}'),'$.restrict_room_creation_to_administrators') IS NULL",[sql_text(cast),sql_text(now),sql_text(cast)]);
                    }
                    if content_type_is(req,"multipart/form-data") {
                        let stored = store_logo(db,req,body,storage,now,keys,written,logo);
                        if stored != 302 { status = stored; }
                    }
                    sql_rows(db,SETTINGS_DEFAULTS,[]);
                    location = str("/account/edit"); notice = str("✓");
                }
            }
        } else if !admin { status = 403; }
        else if kind == ACCOUNT_BOTS {
            // Accounts::BotsController#create: User.create_bot!, with a webhook when the form sends its URL.
            if !has_params(req,body,"user[",["user[name]","user[avatar]","user[webhook_url]"]) { status = 400; }
            else if !param_of(req,body,"user[name]",value) { status = 500; }
            else {
                sql_rows(db,"INSERT INTO users(name,role,status,bot_token,created_at,updated_at) VALUES(?,2,0,?,?,?)",[sql_text(value),sql_text(random_text(12,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")),sql_text(now),sql_text(now)]);
                let bot = sqlite::last_insert_rowid(db);
                if param_of(req,body,"user[webhook_url]",value) { sql_rows(db,"INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES(?,?,?,?)",[sql_text(bot),sql_text(value),sql_text(now),sql_text(now)]); }
                if staged == 1 {
                    let blob = save_upload(db,upload,"avatar","User",bot,now);
                    if variable_content_type(upload.content_type) { avatar = blob; avatar_user = bot; }
                    if probed_content_type(upload.content_type) { probed = blob; }
                }
                // grant_membership_to_open_rooms
                sql_rows(db,"INSERT INTO memberships(room_id,user_id,created_at,updated_at) SELECT id,?,?,? FROM rooms WHERE type='Rooms::Open'",[sql_text(bot),sql_text(now),sql_text(now)]);
                location = str("/account/bots");
            }
        } else if sql_number(db,"SELECT count(*) FROM users WHERE id=? AND role=2 AND status=0",[sql_text(id)]) == 0 { status = 404; }
        else if kind == ACCOUNT_BOT_KEY {
            sql_rows(db,"UPDATE users SET bot_token=?,updated_at=? WHERE id=?",[sql_text(random_text(12,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")),sql_text(now),sql_text(id)]);
            location = str("/account/bots");
        } else if method == "DELETE" {
            // User#deactivate
            sql_rows(db,"DELETE FROM memberships WHERE user_id=? AND room_id IN (SELECT id FROM rooms WHERE type<>'Rooms::Direct')",[sql_text(id)]);
            sql_rows(db,"DELETE FROM push_subscriptions WHERE user_id=?",[sql_text(id)]);
            sql_rows(db,"DELETE FROM searches WHERE user_id=?",[sql_text(id)]);
            sql_rows(db,"DELETE FROM sessions WHERE user_id=?",[sql_text(id)]);
            sql_rows(db,"UPDATE users SET status=1,email_address=replace(email_address,'@',?),updated_at=? WHERE id=?",[sql_text(str("-deactivated-",random_uuid(),"@")),sql_text(now),sql_text(id)]);
            location = str("/account/bots"); changes.push(ACCESS_CLOSE); changes.push(id); changes.push(0);
        } else if !has_params(req,body,"user[",["user[name]","user[avatar]","user[webhook_url]"]) { status = 400; }
        else {
            // User#update_bot!: a present URL updates or creates the webhook, a blank or missing one deletes it.
            if !param_of(req,body,"user[webhook_url]",value) || trim(value).len == 0 { sql_rows(db,"DELETE FROM webhooks WHERE user_id=?",[sql_text(id)]); }
            else if sql_number(db,"SELECT count(*) FROM webhooks WHERE user_id=?",[sql_text(id)]) > 0 { sql_rows(db,"UPDATE webhooks SET url=?,updated_at=? WHERE user_id=? AND url IS NOT ?",[sql_text(value),sql_text(now),sql_text(id),sql_text(value)]); }
            else { sql_rows(db,"INSERT INTO webhooks(user_id,url,created_at,updated_at) VALUES(?,?,?,?)",[sql_text(id),sql_text(value),sql_text(now),sql_text(now)]); }
            if param_of(req,body,"user[name]",value) { sql_rows(db,"UPDATE users SET name=?,updated_at=? WHERE id=? AND name IS NOT ?",[sql_text(value),sql_text(now),sql_text(id),sql_text(value)]); }
            if staged == 1 {
                purge_attachments(db,"record_type='User' AND name='avatar' AND record_id=?",[sql_text(id)],keys);
                let blob = save_upload(db,upload,"avatar","User",id,now);
                if variable_content_type(upload.content_type) { avatar = blob; avatar_user = id; }
                if probed_content_type(upload.content_type) { probed = blob; }
                sql_rows(db,"UPDATE users SET updated_at=? WHERE id=?",[sql_text(now),sql_text(id)]);
            }
            location = str("/account/bots");
        }
        // A failed request changes nothing.
        if status != 302 { sqlite::fail("account request refused"); }
    };
    if failed.len > 0 && status == 302 { status = 500; for e in failed { write_stderr(str("account update failed: ",e.message,"\n")); } }
    if status != 302 {
        if written.len > 0 { delete_blob_file(storage,written); }
        if status == 403 { respond_empty(out,403); }
        else { http::respond(out,status,"text/plain",if status == 404 { "Not found" } else if status == 400 { "Bad request" } else { "Unable to complete request" }); }
        return true;
    }
    delete_blob_files(storage,keys);
    if avatar > 0 { process_later(MEDIA_AVATAR,avatar,avatar_user,avatar_variation()); }
    if logo > 0 { process_later(MEDIA_LOGO,logo,0,logo_variation(false)); }
    // store_logo's negative logo: a video or audio file, analyzed instead.
    if logo < 0 { process_later(MEDIA_ANALYZE,-logo,0,Variation { .. }); }
    if probed > 0 { process_later(MEDIA_ANALYZE,probed,0,Variation { .. }); }
    redirect_with_notice(out,req,location,notice,cookie_key);
    return true;
}
