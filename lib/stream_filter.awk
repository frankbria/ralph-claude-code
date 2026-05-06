# lib/stream_filter.awk — Ralph live-mode NDJSON stream filter.
#
# Extracted from ralph_loop.sh execute_claude_code() (TAP-1470). Invoked via
#   awk -v st=<start_epoch> -v tc=0 -v ac=0 -v ec=0 -v it=0 -v ct="" -v ti="" \
#       -f lib/stream_filter.awk
#
# Reads Claude CLI NDJSON on stdin and emits a compact, single-line-per-event
# display: tool calls with parameters and elapsed time, sub-agent events,
# error indicators, and a final summary stats line. Text content blocks are
# buffered and filtered to suppress stream metadata noise.
#
# Inputs (via -v):
#   st  — start_epoch (seconds since Unix epoch)
#   tc  — tool count accumulator (start at 0)
#   ac  — agent count accumulator (start at 0)
#   ec  — error count accumulator (start at 0)
#   it  — in-tool-block flag (start at 0)
#   ct  — current tool name (start at "")
#   ti  — current tool input accumulator (start at "")
#
# Behavior must stay byte-for-byte stable: tests/unit/test_stream_filter.bats
# guards the contract via golden-file fixtures.

function flush_text() {
    if (tb == "") return
    # Skip stream metadata noise (session_id, uuid, parent_tool_use_id)
    if (tb ~ /session_id/ || tb ~ /parent_tool_use_id/ || tb ~ /"uuid"[[:space:]]*:/) { tb = ""; return }
    # Skip raw JSON object/array dumps
    if (tb ~ /^\s*[\{\[]/ && tb ~ /"[a-z_]+"[[:space:]]*:/) { tb = ""; return }
    # Skip text dominated by UUIDs (hex-dash patterns)
    if (tb ~ /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) { tb = ""; return }
    # Clean whitespace
    gsub(/^[[:space:]]+/, "", tb)
    gsub(/[[:space:]]+$/, "", tb)
    if (length(tb) < 3) { tb = ""; return }
    # Collapse newlines for compact single-line display
    gsub(/\n+/, " ", tb)
    gsub(/  +/, " ", tb)
    # Truncate long text for monitoring readability
    if (length(tb) > 200) tb = substr(tb, 1, 197) "..."
    printf "  > %s\n", tb
    fflush()
    tb = ""
}
{
    line = $0

    # --- Text delta: buffer for filtered display at block boundaries ---
    if (line ~ /"text_delta"/) {
        txt = line
        sub(/.*"text":"/, "", txt)
        gsub(/\\"/, "\001", txt)
        sub(/".*/, "", txt)
        gsub(/\001/, "\"", txt)
        gsub(/\\n/, "\n", txt)
        gsub(/\\t/, "\t", txt)
        gsub(/\\\\/, "\\", txt)
        tb = tb txt
        next
    }

    # --- Flush buffered text before processing any non-text event ---
    flush_text()

    # --- Tool use start: capture name, reset input accumulator ---
    if (line ~ /"tool_use"/ && line ~ /"content_block_start"/) {
        tc++
        it = 1
        ti = ""
        ct = line
        sub(/.*"name":"/, "", ct)
        sub(/".*/, "", ct)
        next
    }

    # --- Input JSON delta: accumulate tool parameters ---
    if (it && line ~ /"input_json_delta"/) {
        pj = line
        sub(/.*"partial_json":"/, "", pj)
        gsub(/\\"/, "\001", pj)
        sub(/".*/, "", pj)
        gsub(/\001/, "\"", pj)
        gsub(/\\\\/, "\\", pj)
        ti = ti pj
        next
    }

    # --- Content block stop: emit compact tool summary ---
    if (line ~ /"content_block_stop"/) {
        if (it && ct != "") {
            now = systime()
            el = now - st
            mn = int(el / 60)
            sc = el % 60

            # Extract key parameter from accumulated tool input
            param = ""
            if (ct == "Read" || ct == "Write" || ct == "Edit") {
                if (ti ~ /"file_path"/) {
                    param = ti
                    sub(/.*"file_path"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                    # Shorten: show last 2-3 path components
                    n = split(param, parts, /[\/\\]/)
                    if (n > 3) param = ".../" parts[n-2] "/" parts[n-1] "/" parts[n]
                    else if (n > 2) param = ".../" parts[n-1] "/" parts[n]
                }
            } else if (ct == "Bash") {
                if (ti ~ /"command"/) {
                    param = ti
                    sub(/.*"command"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                    gsub(/\\n/, " ", param)
                    if (length(param) > 60) param = substr(param, 1, 57) "..."
                }
            } else if (ct == "Glob" || ct == "Grep") {
                if (ti ~ /"pattern"/) {
                    param = ti
                    sub(/.*"pattern"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                }
            } else if (ct == "Agent") {
                if (ti ~ /"description"/) {
                    param = ti
                    sub(/.*"description"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                }
            } else if (ct == "TodoWrite") {
                if (ti ~ /"task"/) {
                    param = ti
                    sub(/.*"task"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                    if (length(param) > 50) param = substr(param, 1, 47) "..."
                }
            }

            # Compact single-line: tool count, name, parameter, elapsed time
            if (param != "")
                printf "  [%d] %s(%s) [%dm%02ds]\n", tc, ct, param, mn, sc
            else
                printf "  [%d] %s [%dm%02ds]\n", tc, ct, mn, sc
            fflush()

            it = 0; ct = ""; ti = ""
        } else {
            it = 0
        }
        next
    }

    # --- Sub-agent started ---
    if (line ~ /"task_started"/) {
        ac++
        desc = line
        if (desc ~ /"description"/) {
            sub(/.*"description"[[:space:]]*:[[:space:]]*"/, "", desc)
            sub(/".*/, "", desc)
        } else {
            desc = "started"
        }
        printf "\n>> Agent #%d: %s\n", ac, desc
        fflush()
        next
    }

    # --- Sub-agent progress ---
    if (line ~ /"task_progress"/) {
        desc = line
        if (desc ~ /"description"/) {
            sub(/.*"description"[[:space:]]*:[[:space:]]*"/, "", desc)
            sub(/".*/, "", desc)
        } else {
            desc = "working..."
        }
        printf "   ...%s\n", desc
        fflush()
        next
    }

    # --- Error in result ---
    if (line ~ /"is_error"[[:space:]]*:[[:space:]]*true/) {
        ec++
        # Extract error message from "result" or "content" fields
        emsg = line
        if (emsg ~ /"result"[[:space:]]*:[[:space:]]*"/) {
            sub(/.*"result"[[:space:]]*:[[:space:]]*"/, "", emsg)
            sub(/".*/, "", emsg)
        } else if (emsg ~ /"content"[[:space:]]*:[[:space:]]*"/) {
            sub(/.*"content"[[:space:]]*:[[:space:]]*"/, "", emsg)
            sub(/".*/, "", emsg)
        } else {
            emsg = ""
        }
        # Unescape common JSON escapes
        gsub(/\\n/, " ", emsg)
        gsub(/\\"/, "\"", emsg)
        gsub(/\\\\/, "\\", emsg)
        if (length(emsg) > 120) emsg = substr(emsg, 1, 117) "..."
        if (emsg != "") {
            printf "  ❌ Error: %s\n", emsg
        } else {
            printf "  ❌ Error detected in response\n"
        }
        fflush()
        next
    }

    # --- Suppress all other JSONL events (prevent raw JSON leaking to terminal) ---
    next
}
END {
    flush_text()
    cmd = "date +%s"
    cmd | getline now
    close(cmd)
    el = now - st
    mn = int(el / 60)
    sc = el % 60
    printf "\n─── %d tools | %d agents | %d errors | %dm%02ds total ───\n", tc, ac, ec, mn, sc
    fflush()
}
