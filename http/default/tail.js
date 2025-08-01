var parsed_url    = new URL(window.location.href);
var server_host   = window.location.hostname;
var server_port   = window.location.port;
var server_path   = "/cgi-bin/tail.cgi"
var _topic        = parsed_url.searchParams.get("topic")    || topic;
var _offset       = parsed_url.searchParams.get("offset")   || offset;
var _count        = parsed_url.searchParams.get("count")    || count;
var _interval     = parsed_url.searchParams.get("interval") || interval;
var xhttp         = null;
var fetch_timer   = null;
var display_timer = null;
var output        = [];
var dirty         = 1;

function start_timer() {
    if (_topic) {
        start_tail();
        display_timer = setInterval(display_table, _interval);
        document.getElementById("toggle").innerHTML = "pause";
    }
    else {
        document.getElementById("toggle").innerHTML = "error";
        document.getElementById("output").innerHTML = '<pre class="uk-dark">no topic</pre>';
    }
}

function start_tail() {
    var prefix_url = window.location.protocol + "//"
                   + server_host + ":" + server_port
                   + server_path + "/" + _topic;
    var server_url = prefix_url  + "/" + _offset + "/" + _count;
    if (double_encode) {
        server_url += "/1";
    }
    xhttp = new XMLHttpRequest();
    // xhttp.timeout = 15000;
    xhttp.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
            var msg = JSON.parse(this.responseText);
            if (!msg.next_url || msg.next_url == server_url) {
                fetch_timer = setTimeout(tick, 1000, server_url);
                if (msg.next_url == server_url) {
                    update_table(msg);
                }
            }
            else {
                server_url  = msg.next_url;
                fetch_timer = setTimeout(tick, 0, server_url);
                update_table(msg);
            }
        }
        else if (this.readyState == 4) {
            fetch_timer = setTimeout(tick, 1000, server_url);
        }
    };
    fetch_timer = setTimeout(tick, 100, server_url);
}

function update_table(msg) {
    if (msg.payload.length) {
        output.unshift(msg.payload.reverse().join(''));
        while (output.length > _count) {
            output.pop();
        }
        dirty = 1;
    }
}

function display_table() {
    if (dirty) {
        document.getElementById("output").innerHTML = '<pre class="uk-dark">'
            + output.join('') + "</pre>";
        dirty = 0;
    }
}

function tick(server_url) {
    // rewrite server_url match current window.location.protocol
    server_url = window.location.protocol + "//" + server_url.split("//")[1];
    xhttp.open("GET", server_url, true);
    xhttp.send();
}

function playOrPause() {
    var state = document.getElementById("toggle").innerHTML;
    if (state == "pause") {
        clearTimeout(fetch_timer);
        fetch_timer = null;
        clearInterval(display_timer);
        display_timer = null;
        document.getElementById("toggle").innerHTML = "play";
        xhttp.abort();
        xhttp = null
    }
    else {
        start_timer();
    }
}
