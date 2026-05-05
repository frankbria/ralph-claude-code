#!/bin/bash
# ralph_upgrade_project.sh — Propagate updated Ralph runtime files to existing projects
#
# Copies hooks, agents, and merges config from the global Ralph installation
# (~/.ralph/) into Ralph-managed project directories.
#
# Usage:
#   ralph-upgrade-project /path/to/project       Upgrade a single project
#   ralph-upgrade-project --all                   Discover and upgrade all projects
#   ralph-upgrade-project --dry-run /path         Preview changes without modifying
#   ralph-upgrade-project --all --yes             Upgrade all, skip confirmation
#
# Tiers:
#   Tier 1 (always overwrite): hook scripts, agent definitions
#   Tier 2 (merge only):       .ralphrc (append missing sections),
#                               .claude/settings.json (inject missing Ralph hooks)
#   Tier 3 (never touch):      fix_plan.md, status.json, .circuit_breaker_state

set -euo pipefail

RALPH_HOME="${HOME}/.ralph"
RALPH_TEMPLATES="${RALPH_HOME}/templates"
RALPH_AGENTS_SOURCE="${RALPH_TEMPLATES}/agents"
# Ralph-local skills (per-project, not tier-S global). Distinct from
# templates/skills/global/ which is managed by lib/skills_install.sh and
# synced into ~/.claude/skills/ machine-wide. skills-local/ is synced into
# each project's .claude/skills/ so the skill only loads when Claude runs
# in that project.
RALPH_SKILLS_LOCAL_SOURCE="${RALPH_TEMPLATES}/skills-local"
MAX_UPGRADE_BACKUPS=5
VERSION="1.0.0"

# =============================================================================
# Colors and logging (same pattern as install.sh)
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
    local level="$1"; shift
    local msg="$*"
    case "$level" in
        INFO)    echo -e "${BLUE}ℹ${NC}  $msg" ;;
        SUCCESS) echo -e "${GREEN}✓${NC}  $msg" ;;
        WARN)    echo -e "${YELLOW}⚠${NC}  $msg" ;;
        ERROR)   echo -e "${RED}✗${NC}  $msg" ;;
        DRY)     echo -e "${CYAN}▷${NC}  [dry-run] $msg" ;;
        SKIP)    echo -e "   ${YELLOW}↷${NC} $msg" ;;
        *)       echo -e "   $msg" ;;
    esac
}

# =============================================================================
# Global counters for summary
# =============================================================================
declare -g TOTAL_UPDATED=0
declare -g TOTAL_SKIPPED=0
declare -g TOTAL_BACKED_UP=0
declare -g TOTAL_CREATED=0
declare -g TOTAL_ERRORS=0

# Per-project counters (reset in upgrade_single_project)
declare -g PROJ_UPDATED=0
declare -g PROJ_SKIPPED=0
declare -g PROJ_BACKED_UP=0
declare -g PROJ_CREATED=0
declare -g PROJ_ERRORS=0

reset_project_counters() {
    PROJ_UPDATED=0; PROJ_SKIPPED=0; PROJ_BACKED_UP=0; PROJ_CREATED=0; PROJ_ERRORS=0
}

flush_project_counters() {
    TOTAL_UPDATED=$((TOTAL_UPDATED + PROJ_UPDATED))
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + PROJ_SKIPPED))
    TOTAL_BACKED_UP=$((TOTAL_BACKED_UP + PROJ_BACKED_UP))
    TOTAL_CREATED=$((TOTAL_CREATED + PROJ_CREATED))
    TOTAL_ERRORS=$((TOTAL_ERRORS + PROJ_ERRORS))
}

# =============================================================================
# Project detection
# =============================================================================

is_ralph_project() {
    local path="$1"
    [[ -d "$path/.ralph" ]] && \
        { [[ -f "$path/.ralph/fix_plan.md" ]] || [[ -f "$path/.ralphrc" ]] || \
          [[ -f "$path/.ralph/PROMPT.md" ]]; }
}

detect_ralph_projects() {
    local -a search_dirs=()

    # Use RALPH_PROJECT_DIRS if set
    if [[ -n "${RALPH_PROJECT_DIRS:-}" ]]; then
        IFS=':' read -ra search_dirs <<< "$RALPH_PROJECT_DIRS"
    fi

    # Platform-specific defaults
    for candidate in \
        "/c/cursor" "/mnt/c/cursor" "$HOME/cursor" \
        "$HOME/projects" "$HOME/code" "$HOME/src" \
        "$HOME/dev" "$HOME/repos"; do
        [[ -d "$candidate" ]] && search_dirs+=("$candidate")
    done

    local -a projects=()
    for dir in "${search_dirs[@]}"; do
        while IFS= read -r -d '' proj_ralph; do
            local proj_dir
            proj_dir="$(dirname "$proj_ralph")"

            # Skip: temp dirs, node_modules, worktrees, the global install itself
            case "$proj_dir" in
                */node_modules/*|*/tmp.*|*/.claude/worktrees/*|"$RALPH_HOME") continue ;;
            esac

            if is_ralph_project "$proj_dir"; then
                projects+=("$proj_dir")
            fi
        done < <(find "$dir" -maxdepth 3 -type d -name ".ralph" -print0 2>/dev/null)
    done

    # Deduplicate (resolve symlinks)
    printf '%s\n' "${projects[@]}" | sort -u
}

# =============================================================================
# Backup management
# =============================================================================

create_backup() {
    local project="$1"
    local file="$2"  # relative to project root

    local abs="$project/$file"
    [[ ! -f "$abs" ]] && return 0

    local backup_dir="$project/.ralph/.upgrade-backups/$BACKUP_TIMESTAMP"
    local backup_file="$backup_dir/$file"

    mkdir -p "$(dirname "$backup_file")"
    cp "$abs" "$backup_file"
    PROJ_BACKED_UP=$((PROJ_BACKED_UP + 1))
}

prune_old_backups() {
    local project="$1"
    local backup_root="$project/.ralph/.upgrade-backups"
    [[ ! -d "$backup_root" ]] && return 0

    local count
    count=$(ls -1d "$backup_root"/20* 2>/dev/null | wc -l)
    if [[ "$count" -gt "$MAX_UPGRADE_BACKUPS" ]]; then
        local to_remove=$((count - MAX_UPGRADE_BACKUPS))
        ls -1d "$backup_root"/20* | head -"$to_remove" | while read -r old; do
            rm -rf "$old"
        done
    fi
}

# =============================================================================
# Tier 1: Always-overwrite — hooks
# =============================================================================

upgrade_hooks() {
    local project="$1"
    local hooks_src="$RALPH_TEMPLATES/hooks"
    local hooks_dst="$project/.ralph/hooks"

    if [[ ! -d "$hooks_src" ]]; then
        log WARN "No hook templates found at $hooks_src"
        return 0
    fi

    if [[ ! -d "$hooks_dst" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log DRY "Would create $hooks_dst/"
        else
            mkdir -p "$hooks_dst"
            log SUCCESS "Created hooks directory"
        fi
        PROJ_CREATED=$((PROJ_CREATED + 1))
    fi

    for src_hook in "$hooks_src"/*.sh; do
        [[ ! -f "$src_hook" ]] && continue
        local name
        name="$(basename "$src_hook")"
        local dst_hook="$hooks_dst/$name"

        # TAP-1415: capture create-vs-update once at the top so the log
        # message and the counter both branch on the same fact. Previous
        # form incremented PROJ_UPDATED in both cases, leaving Created=0
        # in the summary even after installing many fresh hooks.
        local is_create=true
        [[ -f "$dst_hook" ]] && is_create=false

        # Compare content (strip CR for cross-platform)
        if [[ "$is_create" == "false" ]]; then
            local src_hash dst_hash
            src_hash=$(tr -d $'\r' < "$src_hook" | sha256sum | cut -d' ' -f1)
            dst_hash=$(tr -d $'\r' < "$dst_hook" | sha256sum | cut -d' ' -f1)

            if [[ "$src_hash" == "$dst_hash" ]]; then
                PROJ_SKIPPED=$((PROJ_SKIPPED + 1))
                continue
            fi
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ "$is_create" == "true" ]]; then
                log DRY "Would create hook: $name"
            else
                log DRY "Would update hook: $name"
            fi
        else
            # TAP-661: validate source before touching the project copy.
            if [[ ! -s "$src_hook" ]]; then
                log WARN "Skipping $name — template is empty"
                continue
            fi
            if ! bash -n "$src_hook" 2>/dev/null; then
                log WARN "Skipping $name — template failed syntax check"
                continue
            fi

            create_backup "$project" ".ralph/hooks/$name"
            [[ "$is_create" == "false" ]] && chmod u+w "$dst_hook" 2>/dev/null || true

            # Write to a temp file, syntax-check the copy, then atomic rename.
            local tmp_hook="${dst_hook}.tmp.$$.${RANDOM}"
            tr -d $'\r' < "$src_hook" > "$tmp_hook"
            if ! bash -n "$tmp_hook" 2>/dev/null; then
                rm -f -- "$tmp_hook"
                log ERROR "Hook $name copy failed syntax check — rolling back"
                local bak
                bak=$(ls -1t "$project/.ralph/.upgrade-backups"/*/".ralph/hooks/$name" 2>/dev/null | head -1)
                if [[ -n "$bak" ]]; then
                    cp -f "$bak" "$dst_hook" && log WARN "Restored $name from backup"
                fi
                PROJ_ERRORS=$((PROJ_ERRORS + 1))
                continue
            fi
            mv -f "$tmp_hook" "$dst_hook"
            chmod +x "$dst_hook"
            if [[ "$is_create" == "true" ]]; then
                log SUCCESS "Created hook: $name"
            else
                log SUCCESS "Updated hook: $name"
            fi
        fi
        if [[ "$is_create" == "true" ]]; then
            PROJ_CREATED=$((PROJ_CREATED + 1))
        else
            PROJ_UPDATED=$((PROJ_UPDATED + 1))
        fi
    done
}

# =============================================================================
# Tier 1: Always-overwrite — agent definitions
# =============================================================================

upgrade_agents() {
    local project="$1"
    local agents_dst="$project/.claude/agents"

    if [[ ! -d "$RALPH_AGENTS_SOURCE" ]]; then
        log WARN "No agent templates at $RALPH_AGENTS_SOURCE — skipping agents"
        return 0
    fi

    if [[ ! -d "$agents_dst" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log DRY "Would create $agents_dst/"
        else
            mkdir -p "$agents_dst"
            log SUCCESS "Created agents directory"
        fi
    fi

    for src_agent in "$RALPH_AGENTS_SOURCE"/ralph*.md; do
        [[ ! -f "$src_agent" ]] && continue
        local name
        name="$(basename "$src_agent")"
        local dst_agent="$agents_dst/$name"

        # TAP-1415: track create-vs-update once so log + counter agree.
        local is_create=true
        [[ -f "$dst_agent" ]] && is_create=false

        if [[ "$is_create" == "false" ]]; then
            local src_hash dst_hash
            src_hash=$(tr -d $'\r' < "$src_agent" | sha256sum | cut -d' ' -f1)
            dst_hash=$(tr -d $'\r' < "$dst_agent" | sha256sum | cut -d' ' -f1)

            if [[ "$src_hash" == "$dst_hash" ]]; then
                PROJ_SKIPPED=$((PROJ_SKIPPED + 1))
                continue
            fi
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ "$is_create" == "true" ]]; then
                log DRY "Would create agent: $name"
            else
                log DRY "Would update agent: $name"
            fi
        else
            create_backup "$project" ".claude/agents/$name"
            [[ "$is_create" == "false" ]] && chmod u+w "$dst_agent" 2>/dev/null || true
            tr -d $'\r' < "$src_agent" > "$dst_agent"
            if [[ "$is_create" == "true" ]]; then
                log SUCCESS "Created agent: $name"
            else
                log SUCCESS "Updated agent: $name"
            fi
        fi
        if [[ "$is_create" == "true" ]]; then
            PROJ_CREATED=$((PROJ_CREATED + 1))
        else
            PROJ_UPDATED=$((PROJ_UPDATED + 1))
        fi
    done
}

# =============================================================================
# Tier 1: Ralph-local skills — sync project-scoped skills into .claude/skills/
#         and mirror the same SKILL.md into .cursor/skills/ for Cursor IDE.
# =============================================================================
# Mirrors upgrade_agents() but for skills that should only load when Claude
# runs inside this project (vs. tier-S skills installed globally by
# lib/skills_install.sh). Keeps user-authored skill dirs alone — only refreshes
# directories whose name matches a Ralph-shipped template.
upgrade_skills_local() {
    local project="$1"
    local skills_dst="$project/.claude/skills"
    local cursor_skills_dst="$project/.cursor/skills"

    if [[ ! -d "$RALPH_SKILLS_LOCAL_SOURCE" ]]; then
        # No local skills shipped in this Ralph build — nothing to do. Not
        # a warning: early Ralph versions have no skills-local/ templates.
        return 0
    fi

    # Only create the destination when we actually have a skill to place.
    # Avoids littering .claude/skills/ on projects that never had one.
    local have_any=false
    for src_dir in "$RALPH_SKILLS_LOCAL_SOURCE"/*/; do
        [[ -d "$src_dir" ]] || continue
        have_any=true
        break
    done
    [[ "$have_any" == "false" ]] && return 0

    if [[ ! -d "$skills_dst" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log DRY "Would create $skills_dst/"
        else
            mkdir -p "$skills_dst"
            log SUCCESS "Created skills directory"
        fi
    fi

    for src_dir in "$RALPH_SKILLS_LOCAL_SOURCE"/*/; do
        [[ -d "$src_dir" ]] || continue
        local name
        name="$(basename "$src_dir")"
        local src_skill="$src_dir/SKILL.md"
        local dst_dir="$skills_dst/$name"
        local dst_skill="$dst_dir/SKILL.md"

        if [[ ! -f "$src_skill" ]]; then
            log WARN "Skipping skill with no SKILL.md: $name"
            continue
        fi

        if [[ -f "$dst_skill" ]]; then
            local src_hash dst_hash
            src_hash=$(tr -d $'\r' < "$src_skill" | sha256sum | cut -d' ' -f1)
            dst_hash=$(tr -d $'\r' < "$dst_skill" | sha256sum | cut -d' ' -f1)

            if [[ "$src_hash" == "$dst_hash" ]]; then
                PROJ_SKIPPED=$((PROJ_SKIPPED + 1))
                continue
            fi
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ -f "$dst_skill" ]]; then
                log DRY "Would update skill: $name"
            else
                log DRY "Would create skill: $name"
            fi
            log DRY "Would mirror skill to .cursor/skills/$name/SKILL.md"
        else
            create_backup "$project" ".claude/skills/$name/SKILL.md"
            mkdir -p "$dst_dir"
            [[ -f "$dst_skill" ]] && chmod u+w "$dst_skill" 2>/dev/null || true
            tr -d $'\r' < "$src_skill" > "$dst_skill"
            log SUCCESS "Updated skill: $name"
            local cursor_dir="$cursor_skills_dst/$name"
            local cursor_skill="$cursor_dir/SKILL.md"
            create_backup "$project" ".cursor/skills/$name/SKILL.md"
            mkdir -p "$cursor_dir"
            [[ -f "$cursor_skill" ]] && chmod u+w "$cursor_skill" 2>/dev/null || true
            tr -d $'\r' < "$src_skill" > "$cursor_skill"
            log SUCCESS "Mirrored skill to Cursor: $name"
        fi
        PROJ_UPDATED=$((PROJ_UPDATED + 1))
    done
}

# =============================================================================
# Tier 2: Merge — .ralphrc (append missing sections)
# =============================================================================

merge_ralphrc() {
    local project="$1"
    local project_rc="$project/.ralphrc"
    local template_rc="$RALPH_TEMPLATES/ralphrc.template"

    [[ ! -f "$template_rc" ]] && { log WARN "No ralphrc.template found"; return 0; }
    [[ ! -f "$project_rc" ]] && { log SKIP ".ralphrc does not exist — skipping merge"; return 0; }

    # Extract section headers from template: the line immediately after a "# ====...====" delimiter
    # These are the actual section names like "PROJECT IDENTIFICATION", "LOOP SETTINGS", etc.
    local -a template_sections=()
    while IFS= read -r line; do
        template_sections+=("$line")
    done < <(awk '/^# =+$/ { getline; if ($0 ~ /^# [A-Z]/) { sub(/^# /, ""); print } }' "$template_rc")

    # Find which sections the project file is missing
    # Use case-insensitive matching since older .ralphrc files use lowercase headers
    local -a missing_sections=()
    for section in "${template_sections[@]}"; do
        # Extract core keywords (strip parenthetical, trim) for fuzzy matching
        local core_words
        core_words=$(echo "$section" | sed 's/ *(.*//' | tr '[:upper:]' '[:lower:]')
        if ! grep -qi "$core_words" "$project_rc" 2>/dev/null; then
            missing_sections+=("$section")
        fi
    done

    if [[ ${#missing_sections[@]} -eq 0 ]]; then
        PROJ_SKIPPED=$((PROJ_SKIPPED + 1))
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log DRY "Would append ${#missing_sections[@]} sections to .ralphrc:"
        for s in "${missing_sections[@]}"; do
            log DRY "  + $s"
        done
        PROJ_UPDATED=$((PROJ_UPDATED + 1))
        return 0
    fi

    create_backup "$project" ".ralphrc"

    # Extract and append each missing section from the template
    # Template format:
    #   # =============================================================================
    #   # SECTION NAME
    #   # =============================================================================
    #   content lines...
    #   (next section or EOF)
    for section in "${missing_sections[@]}"; do
        local section_text
        section_text=$(awk -v sect="$section" '
            BEGIN { state=0; buf="" }
            # state 0: scanning for section
            # state 1: found section header, skip closing delimiter
            # state 2: collecting content until next opening delimiter
            state == 0 && index($0, "# " sect) == 1 { state=1; next }
            state == 1 && /^# =+$/ { state=2; next }
            state == 2 && /^# =+$/ { exit }
            state == 2 { buf = buf $0 "\n" }
            END { print buf }
        ' "$template_rc")

        {
            echo ""
            echo "# ============================================================================="
            echo "# $section"
            echo "# ============================================================================="
            printf '%s' "$section_text"
        } >> "$project_rc"
    done

    log SUCCESS "Appended ${#missing_sections[@]} sections to .ralphrc: ${missing_sections[*]}"
    PROJ_UPDATED=$((PROJ_UPDATED + 1))
}

# =============================================================================
# Tier 2: Merge — .claude/settings.json (inject missing Ralph hooks)
# =============================================================================

# Canonical Ralph hook entries (as JSON fragments)
# Each entry: event_type, matcher (or "null"), command, statusMessage (or "null")
RALPH_HOOKS=(
    'SessionStart|startup|bash .ralph/hooks/on-session-start.sh|Injecting Ralph loop context...'
    'Stop|null|bash .ralph/hooks/on-stop.sh|Analyzing Ralph response...'
    'PreToolUse|Bash|bash .ralph/hooks/validate-command.sh|Validating command...'
    'PreToolUse|Edit\|Write|bash .ralph/hooks/protect-ralph-files.sh|Checking file protection...'
    'SubagentStop|null|bash .ralph/hooks/on-subagent-done.sh|null'
    'StopFailure|rate_limit\|server_error|bash .ralph/hooks/on-stop-failure.sh|Handling API error...'
    'TeammateIdle|null|bash .ralph/hooks/on-teammate-idle.sh|Checking teammate work queue...'
    'TaskCompleted|null|bash .ralph/hooks/on-task-completed.sh|Validating task completion...'
)

merge_settings_json() {
    local project="$1"
    local settings="$project/.claude/settings.json"

    # Ensure jq is available
    if ! command -v jq &>/dev/null; then
        log WARN "jq not found — skipping settings.json merge"
        return 0
    fi

    if [[ ! -f "$settings" ]]; then
        # Create from scratch with Ralph hooks only
        if [[ "$DRY_RUN" == "true" ]]; then
            log DRY "Would create .claude/settings.json with Ralph hooks"
            PROJ_CREATED=$((PROJ_CREATED + 1))
            return 0
        fi

        mkdir -p "$project/.claude"
        # Copy the canonical settings from the template
        local canonical="$RALPH_TEMPLATES/../.claude/settings.json"
        if [[ -f "$canonical" ]]; then
            tr -d $'\r' < "$canonical" > "$settings"
            log SUCCESS "Created .claude/settings.json from canonical template"
        else
            # Build minimal settings.json with hooks
            _build_settings_json "$settings"
            log SUCCESS "Created .claude/settings.json with Ralph hooks"
        fi
        PROJ_CREATED=$((PROJ_CREATED + 1))
        return 0
    fi

    # Check which Ralph hooks are missing
    local -a missing_hooks=()
    local current_json
    current_json=$(cat "$settings")

    for entry in "${RALPH_HOOKS[@]}"; do
        IFS='|' read -r event matcher command status_msg <<< "$entry"
        # Check if this command already appears anywhere in settings.json
        if ! echo "$current_json" | jq -e --arg cmd "$command" \
            '.. | objects | select(.command? == $cmd)' &>/dev/null; then
            missing_hooks+=("$entry")
        fi
    done

    if [[ ${#missing_hooks[@]} -eq 0 ]]; then
        PROJ_SKIPPED=$((PROJ_SKIPPED + 1))
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log DRY "Would inject ${#missing_hooks[@]} Ralph hooks into settings.json:"
        for h in "${missing_hooks[@]}"; do
            IFS='|' read -r event _ command _ <<< "$h"
            log DRY "  + $event: $command"
        done
        PROJ_UPDATED=$((PROJ_UPDATED + 1))
        return 0
    fi

    create_backup "$project" ".claude/settings.json"

    # Inject missing hooks via jq
    local updated_json="$current_json"
    for entry in "${missing_hooks[@]}"; do
        IFS='|' read -r event matcher command status_msg <<< "$entry"

        # Build the hook object
        local hook_obj
        if [[ "$status_msg" == "null" ]]; then
            hook_obj=$(jq -n --arg cmd "$command" '{"type":"command","command":$cmd}')
        else
            hook_obj=$(jq -n --arg cmd "$command" --arg sm "$status_msg" \
                '{"type":"command","command":$cmd,"statusMessage":$sm}')
        fi

        # Build the event entry (with or without matcher)
        local event_entry
        if [[ "$matcher" == "null" ]]; then
            event_entry=$(jq -n --argjson hook "$hook_obj" '{"hooks":[$hook]}')
        else
            event_entry=$(jq -n --arg m "$matcher" --argjson hook "$hook_obj" \
                '{"matcher":$m,"hooks":[$hook]}')
        fi

        # Ensure hooks object and event array exist, then append
        updated_json=$(echo "$updated_json" | jq \
            --arg event "$event" \
            --argjson entry "$event_entry" \
            '.hooks //= {} | .hooks[$event] //= [] | .hooks[$event] += [$entry]')
    done

    echo "$updated_json" | jq '.' > "$settings"
    log SUCCESS "Injected ${#missing_hooks[@]} Ralph hooks into settings.json"
    PROJ_UPDATED=$((PROJ_UPDATED + 1))
}

# Build a minimal settings.json when creating from scratch
_build_settings_json() {
    local target="$1"
    local json='{}'

    for entry in "${RALPH_HOOKS[@]}"; do
        IFS='|' read -r event matcher command status_msg <<< "$entry"

        local hook_obj
        if [[ "$status_msg" == "null" ]]; then
            hook_obj=$(jq -n --arg cmd "$command" '{"type":"command","command":$cmd}')
        else
            hook_obj=$(jq -n --arg cmd "$command" --arg sm "$status_msg" \
                '{"type":"command","command":$cmd,"statusMessage":$sm}')
        fi

        local event_entry
        if [[ "$matcher" == "null" ]]; then
            event_entry=$(jq -n --argjson hook "$hook_obj" '{"hooks":[$hook]}')
        else
            event_entry=$(jq -n --arg m "$matcher" --argjson hook "$hook_obj" \
                '{"matcher":$m,"hooks":[$hook]}')
        fi

        json=$(echo "$json" | jq \
            --arg event "$event" \
            --argjson entry "$event_entry" \
            '.hooks //= {} | .hooks[$event] //= [] | .hooks[$event] += [$entry]')
    done

    echo "$json" | jq '.' > "$target"
}

# =============================================================================
# Tier 2: Merge — .ralph/PROMPT.md (replace only the RALPH-managed section)
# =============================================================================
# Replaces the content between <!-- RALPH:START ... --> and <!-- RALPH:END -->
# in the project's PROMPT.md with the matching section from the template.
# Lines outside the markers are never touched, preserving user customizations.
# Projects without the markers (old installs) are skipped — never overwritten.

upgrade_prompt_md() {
    local project="$1"
    local project_prompt="$project/.ralph/PROMPT.md"
    local template_prompt="$RALPH_TEMPLATES/PROMPT.md"

    [[ ! -f "$template_prompt" ]] && { log WARN "No PROMPT.md template at $template_prompt — skipping"; return 0; }
    [[ ! -f "$project_prompt" ]] && { log SKIP ".ralph/PROMPT.md does not exist — skipping marker upgrade"; return 0; }

    # Only upgrade if the project file already has the markers (opt-in)
    if ! grep -q '<!-- RALPH:START' "$project_prompt" 2>/dev/null; then
        log SKIP ".ralph/PROMPT.md has no RALPH markers — skipping (add markers or re-run ralph-setup to opt in)"
        return 0
    fi
    if ! grep -q '<!-- RALPH:END' "$project_prompt" 2>/dev/null; then
        log WARN ".ralph/PROMPT.md has RALPH:START but no RALPH:END — skipping (malformed markers)"
        return 0
    fi

    # Extract the managed section from the template
    local template_section
    template_section=$(awk '/<!-- RALPH:START/,/<!-- RALPH:END -->/' "$template_prompt" 2>/dev/null)
    if [[ -z "$template_section" ]]; then
        log WARN "PROMPT.md template has empty RALPH section — skipping"
        return 0
    fi

    # Extract the managed section from the project file for comparison
    local project_section
    project_section=$(awk '/<!-- RALPH:START/,/<!-- RALPH:END -->/' "$project_prompt" 2>/dev/null)

    # Hash comparison — skip if already current (strip CR for cross-platform)
    local tmpl_hash proj_hash
    tmpl_hash=$(printf '%s' "$template_section" | tr -d $'\r' | sha256sum | cut -d' ' -f1)
    proj_hash=$(printf '%s' "$project_section" | tr -d $'\r' | sha256sum | cut -d' ' -f1)
    if [[ "$tmpl_hash" == "$proj_hash" ]]; then
        PROJ_SKIPPED=$((PROJ_SKIPPED + 1))
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log DRY "Would refresh RALPH-managed section in .ralph/PROMPT.md"
        PROJ_UPDATED=$((PROJ_UPDATED + 1))
        return 0
    fi

    create_backup "$project" ".ralph/PROMPT.md"

    # Replace the managed section: keep lines before START marker, inject
    # template section, then keep lines after END marker.
    local updated
    updated=$(awk \
        -v tmpl="$template_section" \
        'BEGIN { inside=0; printed=0 }
         /<!-- RALPH:START/ { inside=1; next }
         /<!-- RALPH:END -->/ {
           if (!printed) { printf "%s\n", tmpl; printed=1 }
           inside=0; next
         }
         inside { next }
         { print }' "$project_prompt" 2>/dev/null)

    if [[ -z "$updated" ]]; then
        log WARN "awk replacement produced empty output — skipping to avoid data loss"
        return 0
    fi

    local _tmp
    _tmp=$(mktemp "$project/.ralph/PROMPT.md.XXXXXX")
    printf '%s\n' "$updated" > "$_tmp" && mv "$_tmp" "$project/.ralph/PROMPT.md"
    rm -f "$_tmp" 2>/dev/null

    log SUCCESS "Refreshed RALPH-managed section in .ralph/PROMPT.md"
    PROJ_UPDATED=$((PROJ_UPDATED + 1))
}

# =============================================================================
# Single-project orchestrator
# =============================================================================

upgrade_single_project() {
    local project="$1"
    reset_project_counters

    # Resolve to absolute path
    project="$(cd "$project" && pwd)"

    if ! is_ralph_project "$project"; then
        log ERROR "Not a Ralph project: $project"
        return 1
    fi

    local project_name
    project_name="$(basename "$project")"

    echo ""
    log INFO "${BOLD}Upgrading: $project_name${NC}  ($project)"
    echo "   ─────────────────────────────────────────"

    # Tier 1: hooks
    upgrade_hooks "$project"

    # Tier 1: agents
    upgrade_agents "$project"

    # Tier 1: Ralph-local skills (.claude/skills/)
    upgrade_skills_local "$project"

    # Tier 2: .ralphrc
    merge_ralphrc "$project"

    # Tier 2: settings.json
    merge_settings_json "$project"

    # Tier 2: .ralph/PROMPT.md (marker-bounded section only)
    upgrade_prompt_md "$project"

    # Prune old backups
    if [[ "$DRY_RUN" != "true" ]]; then
        prune_old_backups "$project"
    fi

    flush_project_counters

    echo ""
    echo "   Updated: $PROJ_UPDATED  Created: $PROJ_CREATED  Skipped: $PROJ_SKIPPED  Backed up: $PROJ_BACKED_UP"
}

# =============================================================================
# Multi-project discovery and upgrade
# =============================================================================

upgrade_all_projects() {
    log INFO "Scanning for Ralph-managed projects..."

    local -a projects=()
    while IFS= read -r proj; do
        [[ -n "$proj" ]] && projects+=("$proj")
    done < <(detect_ralph_projects)

    if [[ ${#projects[@]} -eq 0 ]]; then
        log WARN "No Ralph projects found"
        echo "  Set RALPH_PROJECT_DIRS or use --search-dir to specify where to look"
        return 0
    fi

    echo ""
    log INFO "Found ${#projects[@]} Ralph project(s):"
    for p in "${projects[@]}"; do
        echo "   • $(basename "$p")  ($p)"
    done
    echo ""

    if [[ "$AUTO_YES" != "true" && "$DRY_RUN" != "true" ]]; then
        echo -n "Proceed with upgrade? [y/N] "
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { log INFO "Aborted."; return 0; }
    fi

    for project in "${projects[@]}"; do
        upgrade_single_project "$project"
    done
}

# =============================================================================
# Summary
# =============================================================================

print_summary() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo " Ralph Upgrade Summary"
    echo "═══════════════════════════════════════════════"
    echo "  Files updated:   $TOTAL_UPDATED"
    echo "  Files created:   $TOTAL_CREATED"
    echo "  Files skipped:   $TOTAL_SKIPPED  (already current)"
    echo "  Files backed up: $TOTAL_BACKED_UP"
    echo "═══════════════════════════════════════════════"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        log INFO "Dry run complete. No files were modified."
        echo "  Run without --dry-run to apply changes."
    fi
}

# =============================================================================
# Preflight checks
# =============================================================================

preflight() {
    if [[ ! -d "$RALPH_HOME" ]]; then
        log ERROR "Ralph not installed. Expected global install at $RALPH_HOME"
        log ERROR "Run install.sh first."
        exit 1
    fi

    if [[ ! -d "$RALPH_TEMPLATES" ]]; then
        log ERROR "Templates not found at $RALPH_TEMPLATES"
        exit 1
    fi

    if [[ ! -d "$RALPH_TEMPLATES/hooks" ]]; then
        log ERROR "Hook templates not found at $RALPH_TEMPLATES/hooks"
        exit 1
    fi

    # Agent templates — check and warn (install.sh may not have copied them yet)
    if [[ ! -d "$RALPH_AGENTS_SOURCE" ]]; then
        log WARN "Agent templates not found at $RALPH_AGENTS_SOURCE"
        log WARN "Run install.sh to populate them, or agent upgrade will be skipped."
    fi
}

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat << 'EOF'
ralph-upgrade-project — Propagate Ralph updates to existing projects

USAGE:
  ralph-upgrade-project [OPTIONS] [project_path]
  ralph-upgrade-project --all [OPTIONS]

OPTIONS:
  --all              Discover and upgrade all Ralph projects
  --dry-run          Preview changes without modifying files
  --yes, -y          Skip confirmation prompts
  --hooks-only       Only update hook scripts (skip agents, config merges)
  --skip-merge       Skip .ralphrc and settings.json merges
  --search-dir DIR   Additional parent directory to scan (repeatable)
  -v, --verbose      Verbose output
  -h, --help         Show this help
  --version          Show version

ENVIRONMENT:
  RALPH_PROJECT_DIRS   Colon-separated list of parent directories to scan

EXAMPLES:
  ralph-upgrade-project ~/projects/my-app
  ralph-upgrade-project --all --dry-run
  ralph-upgrade-project --all --yes --search-dir /c/cursor

BACKUP:
  Every overwritten file is backed up to .ralph/.upgrade-backups/YYYYMMDD-HHMMSS/
  Maximum 5 backups retained (configurable via MAX_UPGRADE_BACKUPS).
EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
    local mode=""  # "single" or "all"
    local target_path=""
    local -a extra_search_dirs=()

    # Globals
    DRY_RUN="false"
    AUTO_YES="false"
    HOOKS_ONLY="false"
    SKIP_MERGE="false"
    VERBOSE="false"
    BACKUP_TIMESTAMP=$(date +%Y%m%d-%H%M%S)

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)       mode="all" ;;
            --dry-run)   DRY_RUN="true" ;;
            --yes|-y)    AUTO_YES="true" ;;
            --hooks-only) HOOKS_ONLY="true" ;;
            --skip-merge) SKIP_MERGE="true" ;;
            --search-dir)
                shift
                [[ -d "$1" ]] && extra_search_dirs+=("$1") || log WARN "Not a directory: $1"
                ;;
            -v|--verbose) VERBOSE="true" ;;
            -h|--help)   usage; exit 0 ;;
            --version)   echo "ralph-upgrade-project v$VERSION"; exit 0 ;;
            -*)          log ERROR "Unknown option: $1"; usage; exit 1 ;;
            *)
                if [[ -z "$target_path" ]]; then
                    target_path="$1"
                    mode="single"
                else
                    log ERROR "Unexpected argument: $1"; usage; exit 1
                fi
                ;;
        esac
        shift
    done

    if [[ -z "$mode" ]]; then
        usage
        exit 1
    fi

    # Add extra search dirs to env
    if [[ ${#extra_search_dirs[@]} -gt 0 ]]; then
        local joined
        joined=$(IFS=:; echo "${extra_search_dirs[*]}")
        RALPH_PROJECT_DIRS="${RALPH_PROJECT_DIRS:-}:$joined"
        export RALPH_PROJECT_DIRS
    fi

    echo ""
    echo "  ${BOLD}Ralph Project Upgrader${NC} v$VERSION"
    echo "  Source: $RALPH_HOME"
    [[ "$DRY_RUN" == "true" ]] && echo "  ${CYAN}DRY RUN — no files will be modified${NC}"
    echo ""

    preflight

    case "$mode" in
        single) upgrade_single_project "$target_path" ;;
        all)    upgrade_all_projects ;;
    esac

    print_summary
}

main "$@"
