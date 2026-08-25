#!/usr/bin/env bash

set -euo pipefail

current_ref="${1:-${GITHUB_REF_NAME:-}}"
output_file="${2:-release-notes.md}"

if [[ -z "$current_ref" ]]; then
  echo "Usage: $0 <release-tag> [output-file]" >&2
  exit 64
fi

current_commit="$(git rev-parse --verify "${current_ref}^{commit}")"

case "$current_ref" in
  dev-v*) tag_pattern='dev-v*' ;;
  release-v*) tag_pattern='release-v*' ;;
  *) tag_pattern='*' ;;
esac

previous_tag=''
if git rev-parse --verify "${current_commit}^" >/dev/null 2>&1; then
  previous_tag="$(
    git describe \
      --tags \
      --abbrev=0 \
      --match "$tag_pattern" \
      "${current_commit}^" 2>/dev/null || true
  )"

  if [[ -z "$previous_tag" && "$tag_pattern" != '*' ]]; then
    previous_tag="$(
      git describe \
        --tags \
        --abbrev=0 \
        "${current_commit}^" 2>/dev/null || true
    )"
  fi
fi

if [[ -n "$previous_tag" ]]; then
  revision_range="${previous_tag}..${current_commit}"
else
  revision_range="$current_commit"
fi

breaking_changes=()
features=()
performance_improvements=()
fixes=()
experience_improvements=()
other_updates=()
conventional_pattern='^([a-z]+)(\([^)]*\))?(!)?:[[:space:]]*(.+)$'

while IFS=$'\t' read -r commit subject; do
  [[ -z "$commit" || -z "$subject" ]] && continue

  if [[ "$subject" =~ $conventional_pattern ]]; then
    commit_type="${BASH_REMATCH[1]}"
    commit_scope="${BASH_REMATCH[2]}"
    breaking_marker="${BASH_REMATCH[3]}"
    description="${BASH_REMATCH[4]}"
    commit_scope="${commit_scope#(}"
    commit_scope="${commit_scope%)}"

    case "$commit_scope" in
      build|ci|deps|release|tooling) continue ;;
    esac

    if [[ -n "$breaking_marker" ]]; then
      breaking_changes+=("- $description")
      continue
    fi

    case "$commit_type" in
      feat) features+=("- $description") ;;
      perf) performance_improvements+=("- $description") ;;
      fix|revert) fixes+=("- $description") ;;
      style) experience_improvements+=("- $description") ;;
      build|chore|ci|docs|refactor|test) ;;
      *) other_updates+=("- $description") ;;
    esac
  elif [[ "$subject" != Merge\ * ]]; then
    other_updates+=("- $subject")
  fi
done < <(git log --format='%H%x09%s' "$revision_range")

render_section() {
  local title="$1"
  shift

  [[ "$#" -eq 0 ]] && return
  printf '## %s\n\n' "$title"
  printf '%s\n' "$@"
  printf '\n'
}

repository_url="${WHISPER_RELEASE_REPOSITORY_URL:-${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-lawnvi/whisper}}"
temporary_output="${output_file}.tmp.$$"
trap 'rm -f "$temporary_output"' EXIT
mkdir -p "$(dirname "$output_file")"

{
  render_section '重要变更' "${breaking_changes[@]}"
  render_section '新功能' "${features[@]}"
  render_section '性能优化' "${performance_improvements[@]}"
  render_section '修复与改进' "${fixes[@]}"
  render_section '体验优化' "${experience_improvements[@]}"
  render_section '其他更新' "${other_updates[@]}"

  if ((
    ${#breaking_changes[@]} == 0 &&
    ${#features[@]} == 0 &&
    ${#performance_improvements[@]} == 0 &&
    ${#fixes[@]} == 0 &&
    ${#experience_improvements[@]} == 0 &&
    ${#other_updates[@]} == 0
  )); then
    printf '## 维护更新\n\n- 依赖、构建与发布流程维护\n\n'
  fi

  if [[ -n "$previous_tag" ]]; then
    printf '[查看完整变更](%s/compare/%s...%s)\n' \
      "$repository_url" "$previous_tag" "$current_ref"
  else
    printf '[查看完整提交记录](%s/commits/%s)\n' \
      "$repository_url" "$current_ref"
  fi
} > "$temporary_output"

mv "$temporary_output" "$output_file"
trap - EXIT
