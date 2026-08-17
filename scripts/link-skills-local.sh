#!/usr/bin/env bash
set -euo pipefail

# Fork-local installer: symlinks this repo's skills into Claude Code's personal
# skill directory, so `git pull` keeps the installed set current.
#
# Deliberately a separate file from scripts/link-skills.sh: that one is
# upstream-owned and its header refuses modification, so editing it would
# conflict on every merge from upstream. Keeping fork behaviour here means
# upstream's copy stays byte-identical and mergeable.
#
# Differences from upstream's script:
#   - links into ~/.claude/skills only; upstream also writes ~/.agents/skills
#   - refuses to delete a real directory on a name collision (upstream rm -rf's
#     it, which would destroy a same-named skill installed from another source)
#   - prunes links left behind by skills that were renamed or removed
#   - --dry-run, and per-bucket excludes
#
# Excludes `deprecated` and `in-progress` by default: in-progress skills are
# beta and upstream does not ship them in its plugin either. Pass
# `--include in-progress` for a run that links them.
#
# Usage:
#   scripts/link-skills-local.sh [--dry-run] [--exclude BUCKET]...
#                                [--include BUCKET]... [--dest DIR]
#
# Written for bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${SKILLS_DEST:-$HOME/.claude/skills}"
DRY_RUN=false
EXCLUDES="deprecated in-progress"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --exclude) EXCLUDES="$EXCLUDES $2"; shift 2 ;;
    --include)
      kept=""
      for bucket in $EXCLUDES; do
        [ "$bucket" = "$2" ] || kept="$kept $bucket"
      done
      EXCLUDES="${kept# }"
      shift 2
      ;;
    --dest) DEST="$2"; shift 2 ;;
    # Print the header block, whatever length it grows to.
    -h|--help) awk '/^#!/ {next} /^#/ {sub(/^# ?/, ""); print; found=1; next} found {exit}' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

run() {
  if $DRY_RUN; then
    echo "  would: $*"
  else
    "$@"
  fi
}

excluded() {
  for bucket in $EXCLUDES; do
    [ "$1" = "$bucket" ] && return 0
  done
  return 1
}

names=""
srcs=()
while IFS= read -r -d '' skill_md; do
  src="$(dirname "$skill_md")"
  rel="${src#"$REPO"/skills/}"
  excluded "${rel%%/*}" && continue
  names="$names
$(basename "$src")"
  srcs+=("$src")
done < <(find "$REPO/skills" -name SKILL.md -not -path '*/node_modules/*' -print0)

if [ ${#srcs[@]} -eq 0 ]; then
  echo "error: no skills found under $REPO/skills" >&2
  exit 1
fi

# A $DEST symlinked into this repo would write the per-skill links back into the
# working copy.
if [ -L "$DEST" ]; then
  resolved="$(readlink -f "$DEST")"
  case "$resolved" in
    "$REPO"|"$REPO"/*)
      echo "error: $DEST is a symlink into this repo ($resolved)." >&2
      echo "Remove it and re-run; it will be recreated as a real directory." >&2
      exit 1
      ;;
  esac
fi

run mkdir -p "$DEST"

collisions=0
linked=0
for src in "${srcs[@]}"; do
  name="$(basename "$src")"
  target="$DEST/$name"

  # Never clobber a real directory: it belongs to some other install and is not
  # ours to delete. Report and skip so the operator decides.
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    echo "SKIP $name: $target is a real directory, not a link into this repo" >&2
    collisions=$((collisions + 1))
    continue
  fi

  # Leave links owned by another source alone, for the same reason.
  if [ -L "$target" ]; then
    current="$(readlink "$target")"
    case "$current" in
      "$REPO"/*) : ;;
      *)
        echo "SKIP $name: $target already links elsewhere ($current)" >&2
        collisions=$((collisions + 1))
        continue
        ;;
    esac
  fi

  run ln -sfn "$src" "$target"
  echo "linked $name -> ${src#"$REPO"/}"
  linked=$((linked + 1))
done

# Prune links into this repo whose skill was renamed, removed, or newly
# excluded. Only ever touches links that resolve inside $REPO.
pruned=0
for target in "$DEST"/*; do
  [ -L "$target" ] || continue
  case "$(readlink "$target")" in
    "$REPO"/*) : ;;
    *) continue ;;
  esac
  name="$(basename "$target")"
  case "$names" in
    *"
$name"*) continue ;;
  esac
  run rm -f "$target"
  echo "pruned $name (no longer in this repo)"
  pruned=$((pruned + 1))
done

echo
echo "$linked linked, $pruned pruned, $collisions skipped -> $DEST"
$DRY_RUN && echo "(dry run: nothing changed)"
[ "$collisions" -eq 0 ]
