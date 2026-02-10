#!/bin/bash
# Tool Executor Component for Ralph - Specific Parsing
# Handles extraction and execution of tool calls from LLM output

# Execute a tool call
execute_tool() {
    local tool_name="$1"
    local content="$2"

    log_status "INFO" "🛠 Executing tool: $tool_name"
    
    case "$tool_name" in
        "read_file")
            local path=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="path">(.*?)<\/arg>/s')
            if [[ -f "$path" ]]; then
                echo "--- TOOL RESULT ($tool_name) ---"
                cat "$path"
                echo "-------------------------------"
            else
                echo "Error: File not found: $path"
            fi
            ;;
        "write_file")
            local path=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="path">(.*?)<\/arg>/s')
            local file_content=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="content">(.*?)<\/arg>/s')
            
            if [[ -n "$path" ]]; then
                mkdir -p "$(dirname "$path")"
                echo "$file_content" > "$path"
                echo "--- TOOL RESULT ($tool_name) ---"
                echo "Successfully wrote to $path"
                echo "-------------------------------"
            else
                echo "Error: Missing path for write_file"
            fi
            ;;
        "run_command")
            local cmd=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="command">(.*?)<\/arg>/s')
            if [[ -n "$cmd" ]]; then
                if [[ "$cmd" == *"rm -rf /"* ]]; then
                    echo "Error: Dangerous command blocked"
                else
                    echo "--- TOOL RESULT ($tool_name) ---"
                    eval "$cmd" 2>&1
                    echo "-------------------------------"
                fi
            else
                echo "Error: Missing command for run_command"
            fi
            ;;
        "list_files")
            local dir=$(echo "$content" | perl -0777 -ne 'print $1 if /<arg name="directory">(.*?)<\/arg>/s')
            dir=${dir:-"."}
            echo "--- TOOL RESULT ($tool_name) ---"
            ls -R "$dir"
            echo "-------------------------------"
            ;;
        *)
            echo "Error: Unknown tool: $tool_name"
            ;;
    esac
}

# Process AI response for tool calls
run_tools_if_requested() {
    local input_file="$1"
    local results_file=$(mktemp)
    
    local found_tools=false
    local temp_blocks_dir=$(mktemp -d)
    
    # Use perl to extract each tool_call block
    perl -0777 -ne 'my $i=0; while (/<tool_call(.*?)<\/tool_call>/sg) { open my $fh, ">", "'$temp_blocks_dir'/block_$i.txt"; print $fh "<tool_call$1</tool_call>"; close $fh; $i++; }' "$input_file"
    
    for block_file in "$temp_blocks_dir"/block_*.txt; do
        if [[ -f "$block_file" ]]; then
            found_tools=true
            local block_content=$(cat "$block_file")
            # Extract tool name from the first line of the block
            local tool_name=$(echo "$block_content" | head -n 1 | sed -n 's/.*<tool_call name="\([^"]*\)".*/\1/p')
            execute_tool "$tool_name" "$block_content" >> "$results_file"
        fi
    done
    
    rm -rf "$temp_blocks_dir"
    
    if [[ "$found_tools" == "true" ]]; then
        cat "$results_file"
        rm "$results_file"
        return 0
    else
        rm "$results_file"
        return 1
    fi
}