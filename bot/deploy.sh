#!/usr/bin/env bash
set -euo pipefail

directory="${BOT_INSTALL_DIR:-$HOME/projects/mtproxy-manager-bot}"
repository="${BOT_REPOSITORY:-https://github.com/vdistortion/mtproto-web-proxy-manager.git}"
branch="${BOT_BRANCH:-main}"
revision="${BOT_REVISION:-}"
action="${1:-install}"

fail() { echo "$*" >&2; exit 1; }
save_state() {
    printf '%s\n' "$1" > .deploy/state.tmp
    mv .deploy/state.tmp .deploy/state
    state="$1"
}

sync_repository() {
    [[ "$(git branch --show-current)" == "$branch" ]] || fail "Expected branch: $branch"
    [[ -z "$(git status --porcelain --untracked-files=normal -- . ':(exclude)bot/.deploy')" ]] || fail 'Working tree has local changes.'
    git fetch origin "$branch"
    local target="origin/$branch"
    if [[ -n "$revision" ]]; then
        [[ "$revision" =~ ^[a-f0-9]{40}$ ]] || fail 'BOT_REVISION must be a full commit SHA.'
        git cat-file -e "$revision^{commit}" || fail 'Requested commit was not fetched.'
        git merge-base --is-ancestor "$revision" "origin/$branch" || fail 'Commit is not on the deployment branch.'
        target="$revision"
    fi
    # An older queued workflow must not silently deploy a newer, different commit.
    git merge-base --is-ancestor HEAD "$target" || fail 'Update would rewind or discard local commits.'
    git merge --ff-only "$target"
}

init_project() {
    mkdir -p .deploy
    chmod 700 .deploy
    if [[ -f .deploy/project ]]; then
        IFS= read -r project < .deploy/project
    else
        # Adopt the existing installation only when Docker confirms its working directory.
        local id workdir candidate running
        project=""
        for id in $(docker ps -aq --filter label=com.docker.compose.service=bot); do
            workdir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")
            if [[ "$workdir" == "$directory/bot" ]]; then
                candidate=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$id")
                [[ -z "$project" || "$project" == "$candidate" ]] || fail 'Multiple projects found for this directory.'
                project="$candidate"
                running=$(docker inspect -f '{{.State.Running}}' "$id")
                if [[ ! -f .deploy/state ]]; then
                    if [[ "$running" == true ]]; then save_state active; else save_state stopped; fi
                fi
            fi
        done
        if [[ -z "$project" && "${BOT_ADOPT_LEGACY:-}" == 1 ]]; then
            # Explicit recovery when an old installation has only a volume left.
            [[ -z "$(docker ps -aq --filter label=com.docker.compose.project=bot)" ]] || fail 'Legacy project bot is already in use.'
            docker volume inspect bot_bot-data >/dev/null || fail 'Legacy volume not found.'
            project=bot
        elif [[ -z "$project" ]] && docker volume inspect bot_bot-data >/dev/null 2>&1 && [[ "${BOT_ADOPT_LEGACY:-}" != 0 ]]; then
            fail 'Legacy volume found without an owning container. Set BOT_ADOPT_LEGACY=1 to reuse it, or 0 for a new installation.'
        fi
        if [[ -z "$project" ]]; then
            project="mtproxy-manager-bot-$(printf '%s' "$directory" | sha256sum | cut -c1-12)"
        fi
        printf '%s\n' "$project" > .deploy/project
    fi
    [[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail 'Invalid saved Compose project.'
    state=prepared
    if [[ -f .deploy/state ]]; then IFS= read -r state < .deploy/state; fi
    case "$state" in prepared|active|stopped|removed) ;; *) fail 'Invalid deployment state.' ;; esac
}

compose() {
    docker compose --project-name "$project" "$@"
}

require_settings() {
    [[ -f .env ]] || fail 'Missing bot/.env. Run install or configure first.'
    # Compose permits empty credentials for maintenance operations; startup does not.
    # Validate required interpolation without requiring Node.js on the VPS.
    compose -f compose.yaml -f compose.required.yaml config --quiet
}

ensure_installed() {
    [[ "$state" != removed && "$state" != prepared ]] || fail 'Bot is not installed. Use install/configure explicitly.'
}

apply_configuration() {
    local had_env=0 old_state="$state" old_image="" id
    [[ ! -f .deploy/env.previous ]] || fail 'An unfinished configuration exists in .deploy/env.previous; recover it before retrying.'
    if [[ -f .env ]]; then cp -p .env .deploy/env.previous; had_env=1; fi
    id=$(compose ps -aq bot)
    if [[ -n "$id" ]]; then old_image=$(docker inspect -f '{{.Image}}' "$id"); fi
    mv .env.tmp .env
    if (require_settings && compose build && {
        if [[ "$old_state" == stopped ]]; then compose create --no-build bot;
        else compose up -d --wait --wait-timeout 90; fi
    }); then
        if [[ "$old_state" == stopped ]]; then save_state stopped; else save_state active; fi
        rm -f .deploy/env.previous
        return
    fi
    echo 'Configuration failed; restoring previous settings.' >&2
    if (( had_env )); then mv .deploy/env.previous .env; else rm -f .env; fi
    if [[ -n "$old_image" ]]; then
        if ! docker image tag "$old_image" "$project-bot:local"; then
            echo 'Could not restore the previous image tag.' >&2
            return 1
        fi
        if [[ "$old_state" == active ]]; then
            compose up -d --no-build --wait --wait-timeout 90 || return 1
        else
            compose create --no-build bot || return 1
        fi
    else
        compose down --remove-orphans || return 1
    fi
    save_state "$old_state"
    return 1
}

configure() {
    local old_token old_group old_admins token group admins proxy_directory
    value() { if [[ -f .env ]]; then awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' .env; fi; }
    old_token=$(value VK_TOKEN); old_group=$(value VK_GROUP_ID); old_admins=$(value VK_ADMIN_IDS)
    read -rsp 'VK token (Enter — сохранить существующий): ' token; echo
    token="${token:-$old_token}"
    read -rp "VK group ID [$old_group]: " group; group="${group:-$old_group}"
    read -rp "VK admin IDs через запятую [$old_admins]: " admins; admins="${admins:-$old_admins}"
    proxy_directory="${BOT_PROXY_CONFIG_DIR:-$(value PROXY_CONFIG_DIR)}"
    proxy_directory="${proxy_directory:-/etc/mtproto-manager}"
    proxy_directory="${proxy_directory#\"}"; proxy_directory="${proxy_directory%\"}"
    [[ "$token" =~ ^[A-Za-z0-9_.-]+$ && "$group" =~ ^[1-9][0-9]*$ && "$admins" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || fail 'Некорректный токен или VK ID.'
    [[ "$proxy_directory" == /* && "$proxy_directory" != *[\$\'\"\\]* && "$proxy_directory" != *$'\n'* ]] || fail 'Некорректный путь конфигурации прокси.'
    (umask 077; printf 'VK_TOKEN=%s\nVK_GROUP_ID=%s\nVK_ADMIN_IDS=%s\nPROXY_CONFIG_DIR="%s"\nBOT_DATA_DIR=./data\n' \
        "$token" "$group" "$admins" "$proxy_directory" > .env.tmp)
    apply_configuration
}

main() {
    case "$action" in prepare|install|configure|update|start|stop|restart|status|logs|uninstall|purge) ;; *) fail 'Unknown bot deployment command.' ;; esac
    [[ "$directory" == /* && "$directory" != / ]] || fail 'BOT_INSTALL_DIR must be an absolute directory.'
    directory=$(realpath -m -- "$directory")
    for command in git docker flock sha256sum; do command -v "$command" >/dev/null || fail "Required: $command"; done
    docker compose version >/dev/null
    docker info >/dev/null
    mkdir -p "$(dirname "$directory")"
    exec 9>"${directory}.deploy.lock"
    flock -n 9 || fail 'Another deployment is running.'
    if [[ ! -d "$directory/.git" ]]; then
        [[ "$action" == install || "$action" == prepare ]] || fail "Not installed: $directory"
        git clone --branch "$branch" --single-branch "$repository" "$directory"
    fi
    cd "$directory/bot"
    init_project
    if [[ "$action" == update ]]; then
        if [[ "$state" == removed ]]; then echo 'Bot was removed; update skipped.'; return; fi
        ensure_installed
    fi
    if [[ "$action" == install || "$action" == prepare || "$action" == update ]]; then
        (cd "$directory"; sync_repository)
    fi
    case "$action" in
        prepare)
            if [[ ! -f .env ]]; then (umask 077; cp .env.example .env); fi
            ;;
        install)
            if [[ ! -f .env ]]; then
                (umask 077; cp .env.example .env)
                echo "Fill in $directory/bot/.env, then run install again."
                return
            fi
            require_settings
            compose build --pull
            compose up -d --wait --wait-timeout 90
            save_state active ;;
        configure) configure ;;
        update)
            require_settings
            compose build --pull
            if [[ "$state" == active ]]; then compose up -d --wait --wait-timeout 90; fi ;;
        start|restart)
            ensure_installed
            require_settings
            compose up -d --force-recreate --wait --wait-timeout 90
            save_state active ;;
        stop) ensure_installed; compose stop bot; save_state stopped ;;
        status) echo "State: $state; Compose project: $project"; compose ps -a ;;
        logs) compose logs --tail=100 bot ;;
        uninstall|purge)
            if [[ "$action" == purge ]]; then compose down --remove-orphans --volumes; else compose down --remove-orphans; fi
            save_state removed
            if [[ "$action" == purge ]]; then rm -f .env .env.tmp .deploy/env.previous; fi ;;
    esac
}

main "$@"
