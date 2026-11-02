namespace campfire;
import std;
import sqlite;
import json;
import base64;
import auth;
import html;
import view_data;
import view_types;
import view_helpers;
import view_assets_generated;
import storage;

fn ruby_number(value: f64, integer: bool) -> u8[>..] {
    if integer { return str(value as i64); }
    var out=str(value); if find(out,".")<0 && find(out,"e")<0 { out.append(".0"); } return out;
}

fn attachment_presentation(db: sqlite::Db, id: i64, key: const u8[:], bytes: u8[>..]&, message: MessageView&) -> bool {
    var q=sqlite::Stmt {}; var found=false;
    let failed=sqlite::run() {
        q=sqlite::prepare(db,"SELECT b.id,b.filename,b.content_type,b.metadata FROM active_storage_attachments a JOIN active_storage_blobs b ON b.id=a.blob_id WHERE a.record_type='Message' AND a.record_id=? AND a.name='attachment' LIMIT 1"); sqlite::bind_i64(q,1,id);
        if sqlite::step(q) {
            found=true; message.has_attachment=true;
            let blob=sqlite::column_i64(q,0); let raw_filename=view_text(q,1); let filename=sanitized_filename(raw_filename); let content_type=view_text(q,2);
            let path=blob_redirect_path(blob,raw_filename,"",key); let download=str(path,"?disposition=attachment");
            message.attachment=AttachmentView { filename:view_keep(bytes,filename),blob_path:view_keep(bytes,path),download_path:view_keep(bytes,download) };
            var body: u8[>..]=[];
            let video=starts_with(content_type,"video/");
            let variable=variable_content_type(content_type);
            if video || variable {
                // A video's preview(format: :webp, resize_to_limit: [...]), or the image's representation(:thumb).
                let variation=if video { named_variation("webp",THUMBNAIL_MAX_WIDTH,THUMBNAIL_MAX_HEIGHT) } else { thumb_variation(content_type,raw_filename) };
                let thumb=representation_path(blob,raw_filename,variation,key);
                let metadata=view_text(q,3); var nodes: json::Node[>..]=[]; var strings: u8[>..]=[]; let root,error=json::parse(metadata,nodes,strings);
                var width,has_width=json::as_f64(json::member(root,"width")); var height,has_height=json::as_f64(json::member(root,"height"));
                let wi,width_integer=json::as_i64(json::member(root,"width")); let hi,height_integer=json::as_i64(json::member(root,"height"));
                let scaled=width>1200.0 || height>800.0;
                if scaled { let factor=min(1200.0/width,800.0/height); width*=factor; height*=factor; }
                let sized=has_width && has_height && width>0.0 && height>0.0;
                if sized { format(body,"<div class=\"max-inline-size center flex overflow-clip\" style=\"width: ",ruby_number(if width_integer && !scaled { (wi/2) as f64 } else { width/2.0 },width_integer && !scaled),"px; aspect-ratio: ",ruby_number(width/height,false),";\">"); }
                else { body.append("<div class=\"max-inline-size center overflow-clip\">"); }
                if video { body.append("<video src=\""); escape(body,path); body.append("\" poster=\""); escape(body,thumb); body.append("\" controls=\"controls\" preload=\"none\" width=\"100%\" height=\"100%\" class=\"message__attachment\"></video>"); }
                else {
                    body.append("<a class=\"flex\" data-lightbox-target=\"image\" data-action=\"lightbox#open\" data-lightbox-url-value=\""); escape(body,download); body.append("\" href=\""); escape(body,path); body.append("\"><img");
                    if sized { format(body," width=\"",ruby_number(width,width_integer && !scaled),"\" height=\"",ruby_number(height,height_integer && !scaled),"\""); }
                    body.append(" class=\"message__attachment\" loading=\"lazy\" src=\""); escape(body,thumb); body.append("\" /></a>");
                }
                body.append("</div>");
            } else {
                body.append("<div class=\"flex-inline align-center gap-half\">"); body.append(image_html("common-file-text.svg",[html_attr("class","colorize--black"),html_attr("aria-hidden","true"),html_attr("size",22)]));
                body.append("<span>"); escape(body,filename); body.append("</span><a class=\"btn message__action-btn hide-in-ios-pwa\" style=\"--width: auto;\" href=\""); escape(body,download); body.append("\">");
                body.append(image_html("download.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); body.append("<span class=\"for-screen-reader\">Download "); escape(body,filename); body.append("</span></a>");
                body.append("<button class=\"btn message__action-btn\" style=\"--width: auto;\" data-controller=\"web-share\" data-action=\"web-share#share\" data-web-share-files-value=\""); escape(body,download); body.append("\">");
                body.append(image_html("share.svg",[html_attr("aria-hidden","true"),html_attr("size",20)])); body.append("<span class=\"for-screen-reader\">Share "); escape(body,filename); body.append("</span></button></div>");
            }
            message.presentation=view_keep(bytes,body);
        }
    };
    sqlite::finalize(q); for e in failed { sqlite::fail(e.code,e.message); } return found;
}
