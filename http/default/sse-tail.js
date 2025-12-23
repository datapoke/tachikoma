const parsed_url = new URL(window.location.href);
const server_path = "cgi-bin/sse-tail.cgi";
const _topic = parsed_url.searchParams.get("topic") || topic;
const _offset = parsed_url.searchParams.get("offset") || offset;
const _count = parsed_url.searchParams.get("count") || count;

let eventSource = null;
let output = [];
let dirty = 1;
let display_timer = null;
let reconnect_timer = null;
let message_count = 0;

function init() {
    document.getElementById("toggle").addEventListener("click", playOrPause);
    if (_topic) {
        connect();
        display_timer = setInterval(display_table, 33);
    } else {
        document.getElementById("toggle").innerHTML = "error";
        document.getElementById("status").textContent = "no topic specified";
        document.getElementById("output").innerHTML = '<pre class="uk-dark">no topic</pre>';
    }
}

function connect() {
    if (eventSource) {
        eventSource.close();
    }

    const url = `${server_path}/${_topic}/${_offset}/${_count}`;
    eventSource = new EventSource(url);

    updateStatus("connecting...");

    eventSource.onopen = function() {
        updateStatus("connected");
        message_count = 0;
    };

    eventSource.onmessage = function(event) {
        message_count++;
        const data = event.data;
        output.unshift(data + "\n");
        while (output.length > _count) {
            output.pop();
        }
        dirty = 1;
        updateStatus(`connected (${message_count} messages)`);
    };

    eventSource.addEventListener("error", function(event) {
        if (eventSource.readyState === EventSource.CLOSED) {
            updateStatus("disconnected - reconnecting...");
            scheduleReconnect();
        } else if (eventSource.readyState === EventSource.CONNECTING) {
            updateStatus("reconnecting...");
        } else {
            updateStatus("error");
        }
    });

    eventSource.addEventListener("reconnect", function(event) {
        updateStatus("server requested reconnect");
        scheduleReconnect();
    });
}

function scheduleReconnect() {
    if (reconnect_timer) {
        clearTimeout(reconnect_timer);
    }
    reconnect_timer = setTimeout(function() {
        reconnect_timer = null;
        const toggleBtn = document.getElementById("toggle");
        if (toggleBtn.getAttribute("data-state") === "pause") {
            connect();
        }
    }, 1000);
}

function updateStatus(text) {
    document.getElementById("status").textContent = text;
}

function display_table() {
    if (dirty) {
        document.getElementById("output").innerHTML = '<pre class="uk-dark">'
            + output.join('') + "</pre>";
        dirty = 0;
    }
}

function playOrPause() {
    const toggleBtn = document.getElementById("toggle");
    const state = toggleBtn.getAttribute("data-state");

    if (state === "pause") {
        // Pause
        if (eventSource) {
            eventSource.close();
            eventSource = null;
        }
        if (reconnect_timer) {
            clearTimeout(reconnect_timer);
            reconnect_timer = null;
        }
        updateStatus("paused");
        toggleBtn.setAttribute("data-state", "play");
    } else {
        // Play
        connect();
        toggleBtn.setAttribute("data-state", "pause");
    }
}
